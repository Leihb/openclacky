---
name: skill-add
description: Guide for creating new SKILL.md files
disable-model-invocation: false
user-invocable: true
---

# Skill Creation Guide

## SKILL.md Structure

### 1. Front Matter (Required)
```yaml
---
name: skill-name
description: Brief one-line description
disable-model-invocation: false
user-invocable: true
---
```

### 2. Main Content
```markdown
# Skill Title

## Usage
How to invoke: "command description" or `/skill-name`

## Process Steps

### 1. First Step
What to do

### 2. Next Step
Continue the task

## Commands Used
```bash
# Key commands
```

## Notes
- Important points
```

## File Location
`.clacky/skills/{skill-name}/SKILL.md`

## Minimal Example
```markdown
---
name: hello
description: Simple greeting
disable-model-invocation: false
user-invocable: true
---

# Hello Skill

## Usage
Say "hello" or `/hello`

## Process Steps
### 1. Greet user
### 2. Offer help
```
