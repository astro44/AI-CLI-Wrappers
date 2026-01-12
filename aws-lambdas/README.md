# AI Agent Lambdas

AWS Lambda functions for AI agent operations with direct API calls to Claude, Gemini, and Codex.

## Structure

```
aws-lambdas/
├── AI-Agent-Claude/Lambda/     # Claude/Anthropic Lambda
│   └── lambda_function.py
├── AI-Agent-Gemini/Lambda/     # Gemini/Google Lambda
│   └── lambda_function.py
├── AI-Agent-Codex/Lambda/      # Codex/OpenAI Lambda
│   └── lambda_function.py
├── personas/                   # Persona definitions (JSON)
│   ├── code-generator.json
│   └── data-analyst.json
├── skills/                     # Skill definitions (JSON)
│   ├── draft_email.json
│   ├── enrich_profile.json
│   └── generate_code.json
├── sync_config.py              # Sync personas/skills to DynamoDB/S3
└── README.md
```

## Lambda Functions

Each Lambda handles all operations for its provider:

| Lambda | Provider | Model Default |
|--------|----------|---------------|
| AI-Agent-Claude | Anthropic | claude-sonnet-4-20250514 |
| AI-Agent-Gemini | Google | gemini-1.5-pro |
| AI-Agent-Codex | OpenAI | gpt-4-turbo-preview |

### Actions

All Lambdas support these actions:

- `invoke` - Send message to AI with persona, skills, and context
- `create_session` - Create new conversation session
- `get_session` - Get session details
- `list_sessions` - List sessions for a person
- `delete_session` - Delete a session

## Request Format

### Invoke

```json
{
  "action": "invoke",
  "person_id": "user-123",
  "persona_id": "code-generator",
  "skill_ids": ["draft_email", "generate_code"],
  "message": "Generate a Python script for data processing",
  "session_id": "optional-existing-session-id",
  "context": {
    "project": "data-pipeline",
    "language": "python"
  }
}
```

### Session Operations

```json
{"action": "create_session", "person_id": "user-123", "persona_id": "code-generator"}
{"action": "get_session", "session_id": "uuid"}
{"action": "list_sessions", "person_id": "user-123", "limit": 10}
{"action": "delete_session", "session_id": "uuid"}
```

## Response Format

```json
{
  "statusCode": 200,
  "body": {
    "session_id": "uuid",
    "response": "Here's the Python script...",
    "tool_calls": [],
    "tokens_used": {
      "input": 150,
      "output": 200,
      "total": 350
    },
    "model": "claude-sonnet-4-20250514"
  }
}
```

## DynamoDB Schema

Single table design with GSI for querying sessions by person:

```
Table: ai_agent_data

Primary Key: PK (partition), SK (sort)
GSI1: GSI1PK, GSI1SK

Items:
- PERSONA#<id> | META      - Persona definitions
- SKILL#<id>   | META      - Skill definitions
- SESSION#<id> | META      - Session with messages
  - GSI1PK: PERSON#<person_id>
  - GSI1SK: SESSION#<timestamp>
```

## Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| DYNAMODB_TABLE | DynamoDB table name | Yes |
| AWS_REGION | AWS region | No (default: us-east-1) |
| ANTHROPIC_API_KEY | Claude API key | For Claude Lambda |
| GOOGLE_API_KEY | Gemini API key | For Gemini Lambda |
| OPENAI_API_KEY | OpenAI API key | For Codex Lambda |
| *_SECRET_NAME | Secrets Manager secret name | Alternative to API key env vars |

## Syncing Personas & Skills

Use `sync_config.py` to upload personas and skills to DynamoDB or S3:

```bash
# Sync to DynamoDB
python sync_config.py --target dynamodb --table ai_agent_data --region us-east-1

# Sync to S3
python sync_config.py --target s3 --bucket my-bucket --prefix ai-agent/
```

## Deployment

### Dependencies

Each Lambda needs its provider SDK vendored:

```bash
# Claude
cd AI-Agent-Claude/Lambda
pip install anthropic -t .

# Gemini
cd AI-Agent-Gemini/Lambda
pip install google-generativeai -t .

# Codex
cd AI-Agent-Codex/Lambda
pip install openai -t .
```

### Package for Upload

```bash
cd AI-Agent-Claude/Lambda
zip -r ../AI-Agent-Claude.zip .
```

### IAM Permissions

Lambdas need:
- `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:DeleteItem`, `dynamodb:Query`
- `secretsmanager:GetSecretValue` (if using Secrets Manager for API keys)

## Adding New Personas

1. Create JSON file in `personas/` directory
2. Run `sync_config.py` to upload to DynamoDB
3. Reference by `persona_id` in invoke requests

### Persona Schema

```json
{
  "persona_id": "my-persona",
  "name": "Display Name",
  "description": "What this persona does",
  "model": "claude-sonnet-4-20250514",
  "model_gemini": "gemini-1.5-pro",
  "model_codex": "gpt-4-turbo-preview",
  "max_tokens": 4096,
  "temperature": 0.7,
  "system_prompt": "You are...",
  "capabilities": ["cap1", "cap2"]
}
```

## Adding New Skills

1. Create JSON file in `skills/` directory
2. Run `sync_config.py` to upload to DynamoDB
3. Reference by `skill_id` in invoke requests

### Skill Schema

```json
{
  "skill_id": "my-skill",
  "name": "my_skill",
  "description": "What this skill does",
  "category": "category",
  "input_schema": {
    "type": "object",
    "properties": {...},
    "required": [...]
  },
  "output_format": {
    "type": "object",
    "properties": {...}
  }
}
```

Skills are converted to:
- Claude: `tools` parameter
- Gemini: `function_declarations`
- Codex: `tools` with `functions`
