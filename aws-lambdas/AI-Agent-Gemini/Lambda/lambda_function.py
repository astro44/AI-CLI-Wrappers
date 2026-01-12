"""
AI-Agent-Gemini Lambda

Handles all Gemini/Google agent operations:
- Invoke: Send messages to Gemini with personas, skills, and context
- Sessions: Manage conversation history
- Personas/Skills: Loaded from DynamoDB

Environment Variables:
- GOOGLE_API_KEY: Gemini API key (or use Secrets Manager)
- DYNAMODB_TABLE: Table for personas, skills, sessions
- AWS_REGION: AWS region (default: us-east-1)
"""

import json
import os
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import boto3
from botocore.exceptions import ClientError

# Google Generative AI SDK - vendored in Lambda package
import google.generativeai as genai

# Initialize clients
dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "us-east-1"))
secrets_client = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "ai_agent_data")
table = dynamodb.Table(TABLE_NAME)


def get_api_key() -> str:
    """Get Google API key from environment or Secrets Manager."""
    api_key = os.environ.get("GOOGLE_API_KEY")
    if api_key:
        return api_key

    # Try Secrets Manager
    secret_name = os.environ.get("GOOGLE_SECRET_NAME", "ai-agent/google-api-key")
    try:
        response = secrets_client.get_secret_value(SecretId=secret_name)
        secret = json.loads(response["SecretString"])
        return secret.get("api_key", secret.get("GOOGLE_API_KEY"))
    except ClientError as e:
        raise ValueError(f"Failed to get API key: {e}")


def configure_gemini():
    """Configure Gemini with API key."""
    genai.configure(api_key=get_api_key())


# ============================================================================
# DynamoDB Operations
# ============================================================================

def get_persona(persona_id: str) -> Optional[Dict[str, Any]]:
    """Fetch persona from DynamoDB."""
    try:
        response = table.get_item(
            Key={"PK": f"PERSONA#{persona_id}", "SK": "META"}
        )
        return response.get("Item")
    except ClientError:
        return None


def get_skill(skill_id: str) -> Optional[Dict[str, Any]]:
    """Fetch skill definition from DynamoDB."""
    try:
        response = table.get_item(
            Key={"PK": f"SKILL#{skill_id}", "SK": "META"}
        )
        return response.get("Item")
    except ClientError:
        return None


def get_skills(skill_ids: List[str]) -> List[Dict[str, Any]]:
    """Fetch multiple skills."""
    skills = []
    for skill_id in skill_ids:
        skill = get_skill(skill_id)
        if skill:
            skills.append(skill)
    return skills


def get_session(session_id: str) -> Optional[Dict[str, Any]]:
    """Fetch session from DynamoDB."""
    try:
        response = table.get_item(
            Key={"PK": f"SESSION#{session_id}", "SK": "META"}
        )
        return response.get("Item")
    except ClientError:
        return None


def create_session(person_id: str, persona_id: str) -> Dict[str, Any]:
    """Create a new session."""
    session_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).isoformat()

    session = {
        "PK": f"SESSION#{session_id}",
        "SK": "META",
        "session_id": session_id,
        "person_id": person_id,
        "persona_id": persona_id,
        "model": "gemini",
        "messages": [],
        "created_at": now,
        "last_active": now,
        "GSI1PK": f"PERSON#{person_id}",
        "GSI1SK": f"SESSION#{now}"
    }

    table.put_item(Item=session)
    return session


def update_session_messages(session_id: str, messages: List[Dict]) -> bool:
    """Update session with new messages."""
    now = datetime.now(timezone.utc).isoformat()
    try:
        table.update_item(
            Key={"PK": f"SESSION#{session_id}", "SK": "META"},
            UpdateExpression="SET messages = :msgs, last_active = :now",
            ExpressionAttributeValues={":msgs": messages, ":now": now}
        )
        return True
    except ClientError:
        return False


def delete_session(session_id: str) -> bool:
    """Delete a session."""
    try:
        table.delete_item(
            Key={"PK": f"SESSION#{session_id}", "SK": "META"}
        )
        return True
    except ClientError:
        return False


def list_sessions(person_id: str, limit: int = 10) -> List[Dict]:
    """List sessions for a person."""
    try:
        response = table.query(
            IndexName="GSI1",
            KeyConditionExpression="GSI1PK = :pk",
            ExpressionAttributeValues={":pk": f"PERSON#{person_id}"},
            ScanIndexForward=False,
            Limit=limit
        )
        return response.get("Items", [])
    except ClientError:
        return []


# ============================================================================
# Gemini Invocation
# ============================================================================

def build_system_instruction(persona: Dict, context: Optional[Dict] = None) -> str:
    """Build system instruction from persona and context."""
    system_prompt = persona.get("system_prompt", "You are a helpful AI assistant.")

    if context:
        system_prompt += "\n\n## Current Context\n"
        for key, value in context.items():
            if isinstance(value, dict):
                system_prompt += f"\n### {key}\n"
                for k, v in value.items():
                    if isinstance(v, list):
                        system_prompt += f"- {k}: {', '.join(str(i) for i in v)}\n"
                    else:
                        system_prompt += f"- {k}: {v}\n"
            elif isinstance(value, list):
                system_prompt += f"\n{key}: {', '.join(str(i) for i in value)}"
            else:
                system_prompt += f"\n{key}: {value}"

    return system_prompt


def skills_to_tools(skills: List[Dict]) -> List:
    """Convert skill definitions to Gemini function declarations."""
    tools = []
    for skill in skills:
        # Convert to Gemini function declaration format
        func_decl = genai.protos.FunctionDeclaration(
            name=skill.get("name", skill.get("skill_id")),
            description=skill.get("description", ""),
            parameters=skill.get("input_schema", {"type": "object", "properties": {}})
        )
        tools.append(func_decl)

    if tools:
        return [genai.protos.Tool(function_declarations=tools)]
    return None


def convert_messages_to_gemini(messages: List[Dict]) -> List[Dict]:
    """Convert standard message format to Gemini format."""
    gemini_messages = []
    for msg in messages:
        role = "model" if msg["role"] == "assistant" else msg["role"]
        gemini_messages.append({
            "role": role,
            "parts": [msg["content"]]
        })
    return gemini_messages


def invoke_gemini(
    messages: List[Dict],
    persona: Dict,
    skills: Optional[List[Dict]] = None,
    context: Optional[Dict] = None
) -> Dict[str, Any]:
    """
    Invoke Gemini with persona, skills, and context.

    Args:
        messages: Conversation history [{role, content}, ...]
        persona: Persona configuration with system_prompt, model, etc.
        skills: Optional list of skill definitions (converted to tools)
        context: Optional context to inject into system prompt

    Returns:
        Response dict with content, tokens_used, etc.
    """
    configure_gemini()

    # Build system instruction
    system_instruction = build_system_instruction(persona, context)

    # Get model config from persona
    model_name = persona.get("model", "gemini-1.5-pro")
    temperature = persona.get("temperature", 0.7)
    max_tokens = persona.get("max_tokens", 4096)

    # Configure generation
    generation_config = genai.GenerationConfig(
        temperature=temperature,
        max_output_tokens=max_tokens
    )

    # Build tools if skills provided
    tools = skills_to_tools(skills) if skills else None

    try:
        # Initialize model with system instruction
        model = genai.GenerativeModel(
            model_name=model_name,
            system_instruction=system_instruction,
            generation_config=generation_config,
            tools=tools
        )

        # Convert messages to Gemini format
        gemini_messages = convert_messages_to_gemini(messages)

        # Start chat and send message
        chat = model.start_chat(history=gemini_messages[:-1] if len(gemini_messages) > 1 else [])
        response = chat.send_message(gemini_messages[-1]["parts"][0] if gemini_messages else "Hello")

        # Extract content and function calls
        content = ""
        function_calls = []

        for part in response.parts:
            if hasattr(part, "text"):
                content += part.text
            elif hasattr(part, "function_call"):
                function_calls.append({
                    "name": part.function_call.name,
                    "args": dict(part.function_call.args)
                })

        # Get token counts if available
        tokens_used = {
            "input": getattr(response, "prompt_token_count", 0) or 0,
            "output": getattr(response, "candidates_token_count", 0) or 0
        }
        tokens_used["total"] = tokens_used["input"] + tokens_used["output"]

        return {
            "success": True,
            "content": content,
            "function_calls": function_calls,
            "model": model_name,
            "tokens_used": tokens_used,
            "finish_reason": response.candidates[0].finish_reason.name if response.candidates else None
        }

    except Exception as e:
        return {
            "success": False,
            "error": str(e),
            "error_type": type(e).__name__
        }


# ============================================================================
# Lambda Handler
# ============================================================================

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler.

    Supports multiple operations via 'action' parameter:
    - invoke: Send message to Gemini
    - create_session: Create new session
    - get_session: Get session details
    - list_sessions: List sessions for a person
    - delete_session: Delete a session
    """
    # Handle API Gateway event format
    if "body" in event:
        body = json.loads(event["body"]) if isinstance(event["body"], str) else event["body"]
    else:
        body = event

    action = body.get("action", "invoke")

    try:
        if action == "invoke":
            return handle_invoke(body)
        elif action == "create_session":
            return handle_create_session(body)
        elif action == "get_session":
            return handle_get_session(body)
        elif action == "list_sessions":
            return handle_list_sessions(body)
        elif action == "delete_session":
            return handle_delete_session(body)
        else:
            return response(400, {"error": f"Unknown action: {action}"})

    except Exception as e:
        return response(500, {"error": str(e), "error_type": type(e).__name__})


def handle_invoke(body: Dict) -> Dict:
    """Handle invoke action."""
    person_id = body.get("person_id")
    persona_id = body.get("persona_id", "default")
    skill_ids = body.get("skill_ids", [])
    message = body.get("message")
    context = body.get("context")
    session_id = body.get("session_id")

    if not message:
        return response(400, {"error": "message is required"})

    # Load persona
    persona = get_persona(persona_id)
    if not persona:
        persona = {
            "system_prompt": "You are a helpful AI assistant.",
            "model": "gemini-1.5-pro",
            "max_tokens": 4096,
            "temperature": 0.7
        }

    # Load skills
    skills = get_skills(skill_ids) if skill_ids else None

    # Get or create session
    if session_id:
        session = get_session(session_id)
        if not session:
            return response(404, {"error": "Session not found"})
        messages = session.get("messages", [])
    else:
        session = create_session(person_id or "anonymous", persona_id)
        session_id = session["session_id"]
        messages = []

    # Add user message
    messages.append({"role": "user", "content": message})

    # Invoke Gemini
    result = invoke_gemini(
        messages=messages,
        persona=persona,
        skills=skills,
        context=context
    )

    if result["success"]:
        messages.append({"role": "assistant", "content": result["content"]})
        update_session_messages(session_id, messages)

        return response(200, {
            "session_id": session_id,
            "response": result["content"],
            "function_calls": result.get("function_calls", []),
            "tokens_used": result["tokens_used"],
            "model": result["model"]
        })
    else:
        return response(500, {
            "error": result["error"],
            "error_type": result.get("error_type")
        })


def handle_create_session(body: Dict) -> Dict:
    """Handle create_session action."""
    person_id = body.get("person_id")
    persona_id = body.get("persona_id", "default")

    if not person_id:
        return response(400, {"error": "person_id is required"})

    session = create_session(person_id, persona_id)

    return response(200, {
        "session_id": session["session_id"],
        "person_id": person_id,
        "persona_id": persona_id,
        "created_at": session["created_at"]
    })


def handle_get_session(body: Dict) -> Dict:
    """Handle get_session action."""
    session_id = body.get("session_id")

    if not session_id:
        return response(400, {"error": "session_id is required"})

    session = get_session(session_id)
    if not session:
        return response(404, {"error": "Session not found"})

    return response(200, {
        "session_id": session["session_id"],
        "person_id": session.get("person_id"),
        "persona_id": session.get("persona_id"),
        "message_count": len(session.get("messages", [])),
        "created_at": session.get("created_at"),
        "last_active": session.get("last_active")
    })


def handle_list_sessions(body: Dict) -> Dict:
    """Handle list_sessions action."""
    person_id = body.get("person_id")
    limit = body.get("limit", 10)

    if not person_id:
        return response(400, {"error": "person_id is required"})

    sessions = list_sessions(person_id, limit)

    return response(200, {
        "person_id": person_id,
        "sessions": [
            {
                "session_id": s["session_id"],
                "persona_id": s.get("persona_id"),
                "message_count": len(s.get("messages", [])),
                "created_at": s.get("created_at"),
                "last_active": s.get("last_active")
            }
            for s in sessions
        ]
    })


def handle_delete_session(body: Dict) -> Dict:
    """Handle delete_session action."""
    session_id = body.get("session_id")

    if not session_id:
        return response(400, {"error": "session_id is required"})

    success = delete_session(session_id)

    if success:
        return response(200, {"deleted": True, "session_id": session_id})
    else:
        return response(404, {"error": "Session not found or delete failed"})


def response(status_code: int, body: Dict) -> Dict:
    """Format Lambda response for API Gateway."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps(body)
    }
