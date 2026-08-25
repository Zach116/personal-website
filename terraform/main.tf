terraform {
    required_providers {
      aws = {
        source = "hashicorp/aws"
        version = "5.83.1"
      }
    }

    backend "s3" {
      bucket         = "my-site-tfstate-12123123122"
      key            = "personal-website/terraform.tfstate"
      region         = "us-east-1"
      use_lockfile   = true
      encrypt        = true
    }
}

provider "aws" {
    region = "us-east-1"
}

//----------------------//
// OIDC provider for GitHub
//----------------------//

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
}

//----------------------//
//S3 Bucket for frontend
//----------------------//


resource "aws_s3_bucket" "frontend_bucket" {
    bucket = "my-site-12123123122"
}

resource "aws_s3_bucket_policy" "site_policy" {
  bucket = aws_s3_bucket.frontend_bucket.id
  policy = data.aws_iam_policy_document.allow_access.json

  depends_on = [
    aws_s3_bucket_public_access_block.disable_public_access_block,
    aws_cloudfront_distribution.s3_distribution
  ]
}

data "aws_iam_policy_document" "allow_access" {
  statement {
    sid = "PolicyForCloudFrontPrivateContent"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${aws_s3_bucket.frontend_bucket.arn}/*",
    ]

    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.s3_distribution.arn]
    }
  }
}

resource "aws_s3_bucket_public_access_block" "disable_public_access_block" {
  bucket = aws_s3_bucket.frontend_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "site_configuration" {
  bucket = aws_s3_bucket.frontend_bucket.id

  index_document {
    suffix = "index.html"
  }
}

variable "mime_types" {
  default = {
    htm    = "text/html"
    html   = "text/html"
    txt    = "text/plain"
    scss   = "text/x-scss"
    css    = "text/css"
    ttf    = "font/ttf"
    woff   = "font/woff"
    woff2  = "font/woff2"
    js     = "application/javascript"
    map    = "application/javascript"
    json   = "application/json"
    jpg    = "image/jpeg"
    png    = "image/png"
    svg    = "image/svg+xml"
    eot    = "application/vnd.ms-fontobject"
    drawio = "application/vnd.jgraph.mxfile"
  }
}

resource "aws_s3_object" "site_upload" {
    for_each        = fileset("../site/", "**/*.*")
    bucket          = "my-site-12123123122"
    key             = replace(each.value, "../site/", "")
    source          = "../site/${each.value}"
    etag            = filemd5("../site/${each.value}")
    content_type    = lookup(var.mime_types, split(".", each.value)[length(split(".", each.value)) - 1])

    depends_on =[
      aws_s3_bucket.frontend_bucket
    ]
}
    
//----------------------//
// S3 Bucket for CF Logs
//----------------------//

resource "aws_s3_bucket" "logs_bucket" {
    bucket = "my-site-logs-31231231"
}

resource "aws_s3_bucket_ownership_controls" "logs_ownership" {
  bucket = aws_s3_bucket.logs_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

//----------------------//
//CloudFront Distribution
//----------------------//

resource "aws_cloudfront_distribution" "s3_distribution" {

  origin {
    domain_name = aws_s3_bucket.frontend_bucket.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
    origin_id = "S3Origin"
  }

  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Distribution for my website"
  default_root_object = "index.html"

  aliases = ["zach-bishop.net"]

  logging_config {
    bucket = aws_s3_bucket.logs_bucket.bucket_domain_name
  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Origin"

    cache_policy_id = aws_cloudfront_cache_policy.short_cache.id

    viewer_protocol_policy = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    acm_certificate_arn = aws_acm_certificate.domain_cert.arn
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
    //cloudfront_default_certificate = true
  }

  depends_on =[
    aws_s3_bucket.logs_bucket,
    aws_acm_certificate_validation.domain_validation
  ]
}

resource "aws_cloudfront_cache_policy" "short_cache" {
  name        = "ShortCachePeriod"
  comment     = "A policy with a 5 min TTL for short caching"
  default_ttl = 300
  max_ttl     = 3600
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }

  depends_on = [aws_acm_certificate.domain_cert]
}

resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "s3-access-control"
  description                       = "Only allow access to frontend S3 through CloudFront"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}


//----------------------//
// ACM with R53 Validation
//----------------------//


resource "aws_acm_certificate" "domain_cert" {
  domain_name       = "zach-bishop.net"
  //subject_alternative_names = ["www.zach-bishop.net"]
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_zone" "primary" {
  name = "zach-bishop.net"
}

resource "aws_route53_record" "domain_record" {
  allow_overwrite = true
  name =  tolist(aws_acm_certificate.domain_cert.domain_validation_options)[0].resource_record_name
  records = [tolist(aws_acm_certificate.domain_cert.domain_validation_options)[0].resource_record_value]
  type = tolist(aws_acm_certificate.domain_cert.domain_validation_options)[0].resource_record_type
  zone_id = aws_route53_zone.primary.zone_id
  ttl = 60
}

resource "aws_acm_certificate_validation" "domain_validation" {
  certificate_arn         = aws_acm_certificate.domain_cert.arn
  validation_record_fqdns = [aws_route53_record.domain_record.fqdn]
}

//----------------------//
// R53 A Alias Record
//----------------------//

resource "aws_route53_record" "alias_record" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "zach-bishop.net"
  type    = "A"
  
  alias {
    name = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = true
  }
}

//Create www CNAME record to point www subdomain to apex domain
/*resource "aws_route53_record" "www_record" {
  zone_id = aws_route53_zone.primary.zone_id
  name    = "www.zach-bishop.net"
  type    = "CNAME"
  ttl     = 300
  
  records = ["zach-bishop.net."]
}*/


//----------------------//
// DynamoDB Table
//----------------------//

resource "aws_dynamodb_table" "statistics_table" {
  name          = "Statistics"
  billing_mode  = "PAY_PER_REQUEST"
  hash_key      = "property"

  attribute {
    name = "property"
    type = "S"
  }
}


resource "aws_dynamodb_table_item" "views_item" {
  table_name = aws_dynamodb_table.statistics_table.name
  hash_key = aws_dynamodb_table.statistics_table.hash_key


  item = <<ITEM
  {
    "property": {"S": "Views"},
    "total": {"N": "134"}
  }
  ITEM

  lifecycle {
    ignore_changes = [item]
  }
}

//----------------------//
// GitHub IAM Role
//----------------------//

resource "aws_iam_role" "github_actions" {
  name = "github-actions-website-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json
}

data "aws_iam_policy_document" "github_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository"
      values   = ["Zach116/personal-website"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:Zach116*/personal-website*:*"]
    }
  }  
}

resource "aws_iam_role_policy" "github_actions" {
  name = "github-actions-permissions"
  role = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_aws_resource_access.json
}

data "aws_iam_policy_document" github_aws_resource_access {
  statement {
    sid    = "S3ObjectAccess"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "${aws_s3_bucket.frontend_bucket.arn}/*",
    ]
  }

  statement {
    sid    = "S3BucketManagement"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketVersioning",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketPolicy",
      "s3:PutBucketPolicy",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketWebsite",
      "s3:PutBucketWebsite",
      "s3:GetBucketOwnershipControls",
      "s3:PutBucketOwnershipControls",
      "s3:GetBucketLogging",
      "s3:PutBucketLogging",
      "s3:GetBucketRequestPayment",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
    ]

    resources = [
      aws_s3_bucket.frontend_bucket.arn,
      aws_s3_bucket.logs_bucket.arn,
    ]
  }


  statement {
    sid    = "TerraformStateBucketAccess"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "arn:aws:s3:::my-site-tfstate-12123123122",
    ]
  }

  statement {
    sid    = "TerraformStateAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "arn:aws:s3:::my-site-tfstate-12123123122/personal-website/terraform.tfstate",
      "arn:aws:s3:::my-site-tfstate-12123123122/personal-website/terraform.tfstate.tflock",
    ]
  }

  statement {
    sid    = "LambdaFunctionManagement"
    effect = "Allow"

    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:GetFunctionCodeSigningConfig",
      "lambda:DeleteFunction",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:GetPolicy",
      "lambda:TagResource",
      "lambda:ListVersionsByFunction",
    ]

    resources = [
      "arn:aws:lambda:*:*:function:access-statistics-db",
    ]
  }

  statement {
    sid    = "IamForLambdaExecutionRole"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:PassRole",
      "iam:TagRole",
      "iam:CreatePolicy",
      "iam:DeletePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:CreatePolicyVersion",
      "iam:DeletePolicyVersion",
      "iam:ListPolicyVersions",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]

    resources = [
      "arn:aws:iam::*:role/iam-for-lambda",
      "arn:aws:iam::*:policy/lambda-exec",
    ]
  }

  statement {
    sid    = "GithubActionsRoleSelfRead"
    effect = "Allow"

    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
    ]

    resources = [
      "arn:aws:iam::*:role/github-actions-website-deploy",
    ]
  }

  statement {
    sid    = "DynamoDbTableAccess"
    effect = "Allow"

    actions = [
      "dynamodb:CreateTable",
      "dynamodb:DeleteTable",
      "dynamodb:DescribeTable",
      "dynamodb:DescribeContinuousBackups",
      "dynamodb:DescribeTimeToLive",
      "dynamodb:ListTagsOfResource",
      "dynamodb:UpdateTable",
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:TagResource",
    ]

    resources = [
      "arn:aws:dynamodb:*:*:table/Statistics",
    ]
  }

  statement {
    sid    = "CloudWatchLogsForApiGw"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
    ]

    resources = [
      "arn:aws:logs:*:*:log-group:/aws/api-gw/*",
    ]
  }

  statement {
    sid    = "CloudFrontManagement"
    effect = "Allow"

    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:GetDistribution",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:TagResource",
      "cloudfront:CreateCachePolicy",
      "cloudfront:GetCachePolicy",
      "cloudfront:UpdateCachePolicy",
      "cloudfront:DeleteCachePolicy",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:GetOriginAccessControl",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    sid    = "AcmCertificateManagement"
    effect = "Allow"

    actions = [
      "acm:RequestCertificate",
      "acm:DescribeCertificate",
      "acm:GetCertificate",
      "acm:DeleteCertificate",
      "acm:AddTagsToCertificate",
      "acm:ListTagsForCertificate",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    sid    = "Route53Management"
    effect = "Allow"

    actions = [
      "route53:CreateHostedZone",
      "route53:GetHostedZone",
      "route53:DeleteHostedZone",
      "route53:ChangeResourceRecordSets",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
      "route53:ListTagsForResource",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    sid    = "ApiGatewayManagement"
    effect = "Allow"

    actions = [
      "apigateway:GET",
      "apigateway:POST",
      "apigateway:PUT",
      "apigateway:DELETE",
      "apigateway:PATCH",
    ]

    resources = [
      "*",
    ]
  }

  statement {
    sid    = "GithubOidcProviderRead"
    effect = "Allow"

    actions = [
      "iam:GetOpenIDConnectProvider",
    ]

    resources = [
      aws_iam_openid_connect_provider.github.arn,
    ]
  }
}


//----------------------//
// Lambda IAM Role
//----------------------//

resource "aws_iam_role" "iam_for_lambda" {
  name               = "iam-for-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
    "${aws_iam_policy.lambda_exec.arn}"
  ])

  role = aws_iam_role.iam_for_lambda.name
  policy_arn = each.value

  depends_on = [aws_iam_policy.lambda_exec]
}

resource "aws_iam_policy" "lambda_exec" {
  name = "lambda-exec"
  description = "IAM policy for accessing logs and database from lambda"
  policy = data.aws_iam_policy_document.lambda_database_access.json
}

data "aws_iam_policy_document" "lambda_database_access" {
  statement {
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:DescribeTable",
      "dynamodb:PutItem"
    ]

    resources = [
      "${aws_dynamodb_table.statistics_table.arn}"
    ]
  }
}

//----------------------//
// Lambda Function
//----------------------//

data "archive_file" "lambda_code_archive" {
  type = "zip"

  source_dir  = "lambda-code"
  output_path = "lambda-code.zip"
}


resource "aws_lambda_function" "lambda_statistics_database" {
  filename      = data.archive_file.lambda_code_archive.output_path
  function_name = "access-statistics-db"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "retrieve-viewer-count.lambda_handler"

  source_code_hash = data.archive_file.lambda_code_archive.output_base64sha256

  runtime = "python3.12"
}

//----------------------//
// API Gateway
//----------------------//

resource "aws_apigatewayv2_api" "lambda" {
  name          = "serverless-lambda-gw"
  protocol_type = "HTTP"

  
  cors_configuration {
    allow_origins = ["https://${aws_cloudfront_distribution.s3_distribution.domain_name}", 
                     "https://zach-bishop.net"]
    allow_methods = ["GET"] 
    allow_headers = ["content-type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token"]
    max_age = 300
  }
  
}

resource "aws_apigatewayv2_stage" "lambda" {
  api_id = aws_apigatewayv2_api.lambda.id

  name        = "serverless-lambda-stage"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn

    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      protocol                = "$context.protocol"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
      }
    )
  }
}

resource "aws_apigatewayv2_integration" "views" {
  api_id = aws_apigatewayv2_api.lambda.id

  integration_uri    = aws_lambda_function.lambda_statistics_database.invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "views" {
  api_id = aws_apigatewayv2_api.lambda.id

  route_key = "GET /db-connection"
  target    = "integrations/${aws_apigatewayv2_integration.views.id}"
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name = "/aws/api-gw/${aws_apigatewayv2_api.lambda.name}"

  retention_in_days = 30
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_statistics_database.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.lambda.execution_arn}/*/*"
}
