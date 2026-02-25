---
name: new
description: Create a new project to start development quickly
disable-model-invocation: false
user-invocable: true
---

# Create New Project

## Usage
When user wants to create a new project:
- "help me create a new project"
- "I want to start a new project called blog"
- "/new my-app"

## Process Steps

### 1. Get Project Name
- Extract project name from user input
- Validate: letters, numbers, underscores, hyphens only
- Must start with a letter

### 2. Check Directory
If directory already exists, ask user to choose a different name

### 3. Clone Template
```bash
git clone git@github.com:clacky-ai/rails-template-7x-starter.git <project_name>
```

### 4. Install Dependencies
```bash
cd <project_name>
./bin/setup
```

### 5. Success Message
Tell user:
- Project created successfully!
- Next step: enter project directory to start development
- Command: `cd <project_name>`

## Error Handling
- Directory exists → Ask for different name
- Git clone fails → Check network connection
- Setup fails → Suggest manual run: ./bin/setup

## Example Interaction
User: "help me create a blog project"

Response:
1. Creating a new project named "blog"
2. Cloning template...
3. Installing dependencies...
4. Done! You can now: `cd blog` to start development
