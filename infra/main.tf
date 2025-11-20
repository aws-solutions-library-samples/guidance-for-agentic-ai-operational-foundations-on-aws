# Data sources
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Agent Container Image
module "container_image" {
  source = "./modules/container-image"

  force_image_rebuild = var.force_image_rebuild
  image_build_tool    = var.container_image_build_tool
  repository_name     = "langgraph-cx-agent"
}

# Agent Memory
resource "aws_bedrockagentcore_memory" "agent_memory" {
  name                  = "CxMemory"
  event_expiry_duration = 30
}

# Bedrock Agent Role
module "bedrock_role" {
  source                   = "./modules/agentcore-iam-role"
  agent_memory_arn         = aws_bedrockagentcore_memory.agent_memory.arn
  container_repository_arn = module.container_image.ecr_repository_arn
  role_name                = var.bedrock_role_name
  knowledge_base_id        = module.kb_stack.knowledge_base_id
  guardrail_id             = module.guardrail.guardrail_id
}

# Knowledge Base Stack
module "kb_stack" {
  source       = "./modules/kb-stack"
  name         = var.kb_stack_name
  kb_model_arn = var.kb_model_arn
}

# Guardrail Module
module "guardrail" {
  source                    = "./modules/bedrock-guardrails"
  guardrail_name            = "agentic-ai-guardrail"
  blocked_input_messaging   = "Your input contains content that violates our policy."
  blocked_outputs_messaging = "The response was blocked due to policy violations."
  description               = "Guardrail for agentic AI foundation"
}

# Cognito Module
module "cognito" {
  source         = "./modules/cognito"
  user_pool_name = var.user_pool_name
}

# Parameters Module (depends on KB, Guardrail, Cognito, and Gateway)
module "parameters" {
  source            = "./modules/parameters"
  knowledge_base_id = module.kb_stack.knowledge_base_id
  guardrail_id      = module.guardrail.guardrail_id
  user_pool_id      = module.cognito.user_pool_id
  client_id         = module.cognito.user_pool_client_id
  ac_stm_memory_id  = aws_bedrockagentcore_memory.agent_memory.id
  gateway_url       = aws_bedrockagentcore_gateway.cx_gateway.gateway_url
  oauth_token_url   = module.cognito.oauth_token_url

  depends_on = [
    module.kb_stack,
    module.guardrail,
    module.cognito,
    aws_bedrockagentcore_gateway.cx_gateway
  ]
}

# Secrets Module (depends on Cognito for client secret)
module "secrets" {
  source = "./modules/secrets"

  cognito_client_secret = module.cognito.client_secret

  # Placeholder values - replace with actual values
  zendesk_domain      = var.zendesk_domain
  zendesk_email       = var.zendesk_email
  zendesk_api_token   = var.zendesk_api_token
  langfuse_host       = var.langfuse_host
  langfuse_public_key = var.langfuse_public_key
  langfuse_secret_key = var.langfuse_secret_key
  gateway_url         = var.gateway_url
  gateway_api_key     = var.gateway_api_key
  tavily_api_key      = var.tavily_api_key

  depends_on = [module.cognito]
}

# Gateway IAM Role
data "aws_iam_policy_document" "gateway_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway_role" {
  name               = "bedrock-agentcore-gateway-role"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json
}

resource "aws_iam_role_policy" "gateway_policy" {
  name = "gateway-external-api-policy"
  role = aws_iam_role.gateway_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = aws_lambda_function.tavily_search.arn
      }
    ]
  })
}

# Bedrock AgentCore Gateway
resource "aws_bedrockagentcore_gateway" "cx_gateway" {
  name     = "cx-agent-gateway"
  role_arn = aws_iam_role.gateway_role.arn

  authorizer_type = "CUSTOM_JWT"
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = module.cognito.user_pool_discovery_url
      allowed_clients = [module.cognito.user_pool_client_id]
    }
  }

  protocol_type = "MCP"
}

# Lambda function for Tavily integration
resource "aws_lambda_function" "tavily_search" {
  filename         = "tavily_lambda.zip"
  function_name    = "tavily-search-function"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "python3.9"
  timeout         = 30

  environment {
    variables = {
      TAVILY_API_KEY = var.tavily_api_key
    }
  }
}

# Lambda IAM Role
resource "aws_iam_role" "lambda_role" {
  name = "tavily-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role.name
}

# Lambda permission for gateway to invoke
resource "aws_lambda_permission" "allow_gateway" {
  statement_id  = "AllowExecutionFromGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.tavily_search.function_name
  principal     = "bedrock-agentcore.amazonaws.com"
  source_arn    = aws_bedrockagentcore_gateway.cx_gateway.gateway_arn
}

# Lambda deployment package
data "archive_file" "tavily_lambda_zip" {
  type        = "zip"
  output_path = "tavily_lambda.zip"
  source {
    content = <<EOF
import json
import os
import urllib.request
import urllib.parse

def handler(event, context):
    print(f"Lambda invoked with event: {json.dumps(event)}")
    print(f"Context: {context}")
    
    api_key = os.environ.get('TAVILY_API_KEY')
    print(f"API key present: {bool(api_key)}")
    
    if not api_key:
        print("ERROR: TAVILY_API_KEY not found in environment")
        return {'error': 'TAVILY_API_KEY not configured'}
    
    # Handle both string input and object input
    if isinstance(event, str):
        query = event
    else:
        query = event.get('query', event) if isinstance(event, dict) else str(event)
    
    print(f"Extracted query: {query}")
    
    if not query:
        print("ERROR: No query provided")
        return {'error': 'Query parameter is required'}
    
    url = 'https://api.tavily.com/search'
    data = {
        'api_key': api_key,
        'query': query,
        'search_depth': 'basic',
        'include_answer': True
    }
    
    print(f"Making request to Tavily API with query: {query}")
    
    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode('utf-8'),
        headers={'Content-Type': 'application/json'}
    )
    
    try:
        with urllib.request.urlopen(req) as response:
            print(f"Tavily API response status: {response.status}")
            result = json.loads(response.read().decode('utf-8'))
            print(f"Tavily API response: {json.dumps(result)[:500]}...")
            
            # Format response for agent understanding
            if 'results' in result:
                formatted_results = []
                for item in result['results'][:3]:  # Limit to top 3 results
                    formatted_results.append({
                        'title': item.get('title', ''),
                        'url': item.get('url', ''),
                        'content': item.get('content', '')[:500]  # Truncate content
                    })
                formatted_response = {
                    'search_results': formatted_results,
                    'answer': result.get('answer', ''),
                    'query': query
                }
                print(f"Returning formatted response: {json.dumps(formatted_response)[:200]}...")
                return formatted_response
            
            print(f"Returning raw result: {json.dumps(result)[:200]}...")
            return result
    except Exception as e:
        print(f"ERROR in Lambda function: {str(e)}")
        import traceback
        print(f"Traceback: {traceback.format_exc()}")
        return {'error': str(e)}
EOF
    filename = "index.py"
  }
}

# Gateway Target for Tavily
resource "aws_bedrockagentcore_gateway_target" "tavily_target" {
  name               = "tavily-search-target"
  gateway_identifier = aws_bedrockagentcore_gateway.cx_gateway.gateway_id
  description        = "Tavily web search integration"

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = aws_lambda_function.tavily_search.arn

        tool_schema {
          inline_payload {
            name        = "tavily_search"
            description = "Search the web using Tavily API"

            input_schema {
              type        = "string"
              description = "Search query for web search"
            }
          }
        }
      }
    }
  }
}

# Deploy the endpoint
resource "aws_bedrockagentcore_agent_runtime" "agent_runtime" {
  agent_runtime_name = "langgraph_cx_agent"
  description        = "Example customer service agent for Agentic AI Foundation"
  role_arn           = module.bedrock_role.role_arn
  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url   = module.cognito.user_pool_discovery_url
      allowed_clients = [module.cognito.user_pool_client_id]
    }
  }
  agent_runtime_artifact {
    container_configuration {
      container_uri = module.container_image.ecr_image_uri
    }
  }
  network_configuration {
    network_mode = "PUBLIC"
  }
  protocol_configuration {
    server_protocol = "HTTP"
  }
  environment_variables = {
    "LOG_LEVEL" = "INFO"
    "OTEL_EXPORTER_OTLP_ENDPOINT" = "${var.langfuse_host}/api/public/otel"
    "OTEL_EXPORTER_OTLP_HEADERS" = "Authorization=Basic ${base64encode("${var.langfuse_public_key}:${var.langfuse_secret_key}")}"
    "DISABLE_ADOT_OBSERVABILITY" = "true",
    "LANGSMITH_OTEL_ENABLED" = "true",
    "LANGSMITH_TRACING" = "true"

  }

}
