# frozen_string_literal: true

require "json"
require "tempfile"

module Clacky
  module DeployTools
    # Create a PostgreSQL database service on Railway and wait for it to be ready.
    #
    # This tool handles the known Railway CLI bug where `railway add` returns an
    # error exit code when using project tokens, but actually succeeds in creating
    # the service.
    #
    # Strategy:
    # 1. Capture existing service IDs before creation
    # 2. Execute `railway add --database postgres` (ignore exit code)
    # 3. Poll for new service ID (max 15 seconds)
    # 4. Wait for DATABASE_URL to be available on the new service (max 2 minutes)
    #
    # @example
    #   result = CreateDatabaseService.execute(
    #     platform_token: "railway-token-here"
    #   )
    #   if result[:success]
    #     puts "Database created: #{result[:service_name]}"
    #     puts "DATABASE_URL: #{result[:database_url]}"
    #   end
    class CreateDatabaseService
      
      # Maximum time to wait for new service to appear after creation command
      DETECTION_TIMEOUT = 15 # seconds
      DETECTION_INTERVAL = 3 # seconds
      
      # Maximum time to wait for DATABASE_URL to be available
      PROVISION_TIMEOUT = 120 # seconds (2 minutes)
      PROVISION_INTERVAL = 5  # seconds
      
      # Execute database creation
      #
      # @param platform_token [String] RAILWAY_TOKEN for authentication
      # @return [Hash] {
      #   success:       Boolean,
      #   service_id:    String (if success),
      #   service_name:  String (if success),
      #   database_url:  String (if success),
      #   error:         String (if failed)
      # }
      def self.execute(platform_token:)
        new(platform_token).execute
      end
      
      def initialize(platform_token)
        @platform_token = platform_token
        @env = { "RAILWAY_TOKEN" => platform_token }
      end
      
      def execute
        # Step 0: Check if database already exists
        existing_db = find_existing_database
        
        if existing_db
          puts "  ✅ Database already exists: #{existing_db[:name]}"
          
          # Return without DATABASE_URL - Railway automatically shares it across services
          return {
            success: true,
            service_id: existing_db[:id],
            service_name: existing_db[:name],
            database_url: nil,  # Don't fetch - Railway auto-injects
            status: "existing"
          }
        end
        
        # No database exists - create new one
        puts "  📦 Creating new PostgreSQL database..."
        
        # Step 1: Get existing service IDs
        existing_service_ids = fetch_service_ids
        
        unless existing_service_ids
          return { success: false, error: "Failed to fetch existing services" }
        end
        
        # Step 2: Execute create command (ignore exit code due to known bug)
        execute_create_command
        
        # Step 3: Detect new service
        new_service = detect_new_service(existing_service_ids)
        
        unless new_service
          return { success: false, error: "Database service not detected after #{DETECTION_TIMEOUT}s" }
        end
        
        # Step 4: Wait for DATABASE_URL
        database_url = wait_for_database_url(new_service[:name])
        
        unless database_url
          return {
            success: false,
            error: "DATABASE_URL not available after #{PROVISION_TIMEOUT}s for service #{new_service[:name]}"
          }
        end
        
        {
          success: true,
          service_id: new_service[:id],
          service_name: new_service[:name],
          database_url: database_url,
          status: "created"
        }
        
      rescue => e
        {
          success: false,
          error: "Unexpected error: #{e.message}"
        }
      end
      
      # Find existing Postgres database service
      # @return [Hash, nil] { id:, name: } or nil if not found
      private def find_existing_database
        Tempfile.create('railway_status') do |tmpfile|
          success = system(
            @env,
            "railway", "status", "--json",
            in: :close,
            out: tmpfile,
            err: File::NULL
          )
          
          return nil unless success
          
          tmpfile.rewind
          output = tmpfile.read.strip
          return nil if output.empty?
          
          begin
            data = JSON.parse(output)
            
            # Navigate to production environment's service instances
            edges = data.dig("environments", "edges")
            return nil unless edges&.any?
            
            prod_env = edges.find { |e| e.dig("node", "name") == "production" }
            return nil unless prod_env
            
            service_edges = prod_env.dig("node", "serviceInstances", "edges")
            return nil unless service_edges
            
            # Find Postgres service (by name pattern or image source)
            postgres_edge = service_edges.find do |edge|
              node = edge["node"]
              next false unless node
              
              service_name = node["serviceName"].to_s
              source_image = node.dig("source", "image").to_s
              
              # Match: name contains "Postgres" or "postgres", or source is postgres image
              service_name.match?(/postgres/i) || source_image.include?("postgres")
            end
            
            return nil unless postgres_edge
            
            node = postgres_edge["node"]
            { id: node["serviceId"], name: node["serviceName"] }
          rescue JSON::ParserError
            nil
          end
        end
      end
      
      # Fetch all existing service IDs from railway status
      # @return [Array<String>, nil] Array of service IDs, or nil on failure
      private def fetch_service_ids
        Tempfile.create('railway_status') do |tmpfile|
          success = system(
            @env,
            "railway", "status", "--json",
            in: :close,
            out: tmpfile,
            err: File::NULL
          )
          
          return nil unless success
          
          tmpfile.rewind
          output = tmpfile.read.strip
          return [] if output.empty?
          
          begin
            data = JSON.parse(output)
            
            # Extract service IDs from environments.edges[0].node.serviceInstances.edges
            edges = data.dig("environments", "edges")
            return [] unless edges&.any?
            
            service_instances = edges[0].dig("node", "serviceInstances", "edges")
            return [] unless service_instances
            
            service_instances.map { |edge| edge.dig("node", "serviceId") }.compact
          rescue JSON::ParserError
            nil
          end
        end
      end
      
      # Execute the railway add command
      # NOTE: We ignore the exit code because Railway CLI has a known bug
      # where it returns error with project tokens but still succeeds
      private def execute_create_command
        system(
          @env,
          "railway", "add", "--database", "postgres",
          in: :close,
          out: File::NULL,
          err: File::NULL
        )
        # Exit code intentionally ignored
      end
      
      # Detect newly created service by comparing service IDs
      # @param existing_ids [Array<String>] Service IDs before creation
      # @return [Hash, nil] { id: String, name: String } or nil if not found
      private def detect_new_service(existing_ids)
        max_attempts = DETECTION_TIMEOUT / DETECTION_INTERVAL
        
        max_attempts.times do
          sleep DETECTION_INTERVAL
          
          current_ids = fetch_service_ids
          next unless current_ids
          
          new_ids = current_ids - existing_ids
          
          if new_ids.any?
            # Fetch full service info to get the name
            return fetch_service_info(new_ids.first)
          end
        end
        
        nil
      end
      
      # Fetch service name for a given service ID
      # @param service_id [String]
      # @return [Hash, nil] { id: String, name: String }
      private def fetch_service_info(service_id)
        Tempfile.create('railway_status') do |tmpfile|
          success = system(
            @env,
            "railway", "status", "--json",
            in: :close,
            out: tmpfile,
            err: File::NULL
          )
          
          return nil unless success
          
          tmpfile.rewind
          output = tmpfile.read.strip
          return nil if output.empty?
          
          begin
            data = JSON.parse(output)
            edges = data.dig("environments", "edges")
            return nil unless edges&.any?
            
            service_instances = edges[0].dig("node", "serviceInstances", "edges")
            return nil unless service_instances
            
            # Find the service with matching ID
            service_node = service_instances.find do |edge|
              edge.dig("node", "serviceId") == service_id
            end
            
            return nil unless service_node
            
            {
              id: service_id,
              name: service_node.dig("node", "serviceName")
            }
          rescue JSON::ParserError
            nil
          end
        end
      end
      
      # Wait for DATABASE_URL to be available on the service
      # @param service_name [String]
      # @return [String, nil] DATABASE_URL or nil if timeout
      private def wait_for_database_url(service_name)
        max_attempts = PROVISION_TIMEOUT / PROVISION_INTERVAL
        
        max_attempts.times do
          sleep PROVISION_INTERVAL
          
          database_url = fetch_database_url(service_name)
          return database_url if database_url
        end
        
        nil
      end
      
      # Fetch DATABASE_URL from service variables
      # @param service_name [String]
      # @return [String, nil] DATABASE_URL value or nil
      private def fetch_database_url(service_name)
        tmpfile = Tempfile.new(['railway_vars', '.json'])
        
        begin
          success = system(
            @env,
            "railway", "variables", "--service", service_name, "--json",
            in: :close,
            out: tmpfile,
            err: File::NULL
          )
          
          return nil unless success
          
          tmpfile.rewind
          output = tmpfile.read.strip
          return nil if output.empty?
          
          begin
            # Output should be a JSON hash of variables
            vars = JSON.parse(output)
            
            # Prefer DATABASE_URL, fall back to DATABASE_PUBLIC_URL
            vars["DATABASE_URL"] || vars["DATABASE_PUBLIC_URL"]
          rescue JSON::ParserError
            nil
          end
        ensure
          tmpfile.close
          tmpfile.unlink
        end
      end
    end
  end
end
