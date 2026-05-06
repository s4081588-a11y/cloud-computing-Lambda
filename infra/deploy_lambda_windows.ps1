param(
    [string]$Region = $env:AWS_REGION,
    [string]$AccountId,
    [string]$Profile,
    [string]$FunctionName = "lambdax-music-api",
    [string]$ApiName = "lambdax-music-http-api",
    [string]$StageName = "prod",
    [string]$FrontendBucket,
    [string]$PrivateBucket,
    [switch]$IncludeDependencies,
    [switch]$SkipFrontendUpload
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Resolve-Path (Join-Path $scriptDir "..")
$backendDir = Join-Path $projectRoot "backend"
$frontendDir = Join-Path $projectRoot "frontend"
$routesFile = Join-Path $scriptDir "api_gateway_routes.txt"
$buildDir = Join-Path $scriptDir ".build_lambda"
$zipPath = Join-Path $scriptDir "lambda_package.zip"
$frontendBuildDir = Join-Path $scriptDir ".build_frontend"

function Invoke-AwsCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $awsArgs = @()
    if ($Profile) {
        $awsArgs += @("--profile", $Profile)
    }
    if ($Region) {
        $awsArgs += @("--region", $Region)
    }

    $awsCli = Get-Command aws.exe -ErrorAction SilentlyContinue
    if (-not $awsCli) {
        throw "AWS CLI was not found. Install AWS CLI v2 and ensure aws.exe is on PATH."
    }

    $previousNativePreference = $null
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
        $previousNativePreference = $Global:PSNativeCommandUseErrorActionPreference
        $Global:PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $output = & aws.exe @awsArgs @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -ne $previousNativePreference) {
            $Global:PSNativeCommandUseErrorActionPreference = $previousNativePreference
        }
    }

    if ($exitCode -ne 0) {
        $rendered = ($output | Out-String).Trim()
        throw "AWS CLI command failed (exit $exitCode): aws $($Arguments -join ' ')`n$rendered"
    }

    return $output
}

function Invoke-AwsJson {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = Invoke-AwsCommand -Arguments $Arguments
    if (-not $output) {
        return $null
    }

    return (($output | Out-String).Trim() | ConvertFrom-Json)
}

function Get-PythonCommand {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @{ Command = "python"; Arguments = @() }
    }

    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @{ Command = "py"; Arguments = @("-3") }
    }

    throw "Python is required only when -IncludeDependencies is set."
}

function Test-AwsResourceExists {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    try {
        Invoke-AwsCommand -Arguments $Arguments | Out-Null
        return $true
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match "AccessDenied|Unauthorized|ExpiredToken|InvalidClientTokenId|UnrecognizedClientException") {
            throw "Unable to verify resource due to AWS credential/permission error while running: aws $($Arguments -join ' ')`n$message"
        }
        return $false
    }
}

function Get-AwsCallerAccount {
    $identity = Invoke-AwsJson -Arguments @("sts", "get-caller-identity")
    return $identity.Account
}

function Assert-Preconditions {
    param(
        [Parameter(Mandatory = $true)][string[]]$TableNames,
        [Parameter(Mandatory = $true)][string]$BucketName,
        [Parameter(Mandatory = $true)][string]$RoleName
    )

    foreach ($tableName in $TableNames) {
        if (-not (Test-AwsResourceExists -Arguments @("dynamodb", "describe-table", "--table-name", $tableName))) {
            throw "Missing required DynamoDB table: $tableName"
        }
    }

    if (-not (Test-AwsResourceExists -Arguments @("s3api", "head-bucket", "--bucket", $BucketName))) {
        throw "Missing required private S3 bucket: $BucketName"
    }

    if (-not (Test-AwsResourceExists -Arguments @("iam", "get-role", "--role-name", $RoleName))) {
        throw "Missing required IAM role: $RoleName"
    }
}

function Ensure-LambdaPackage {
    if (Test-Path $buildDir) {
        Remove-Item -Recurse -Force $buildDir
    }

    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    Copy-Item -Path (Join-Path $backendDir "lambda_function.py") -Destination $buildDir

    if ($IncludeDependencies) {
        $pythonCommand = Get-PythonCommand
        if ($pythonCommand.Command -eq "python") {
            & python -m pip install --upgrade pip | Out-Null
            & python -m pip install -r (Join-Path $backendDir "requirements.txt") -t $buildDir | Out-Null
        }
        else {
            & py -3 -m pip install --upgrade pip | Out-Null
            & py -3 -m pip install -r (Join-Path $backendDir "requirements.txt") -t $buildDir | Out-Null
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Dependency packaging failed."
        }
    }

    if (Test-Path $zipPath) {
        Remove-Item -Force $zipPath
    }

    Compress-Archive -Path (Join-Path $buildDir "*") -DestinationPath $zipPath -Force
}

function Ensure-LambdaFunction {
    $role = Invoke-AwsJson -Arguments @("iam", "get-role", "--role-name", "LabRole")
    $roleArn = $role.Role.Arn

    $envVars = @{
        USERS_TABLE_NAME         = "login"
        MUSIC_TABLE_NAME         = "music"
        SUBSCRIPTIONS_TABLE_NAME = "subscriptions"
        S3_BUCKET_NAME           = $PrivateBucket
        PRESIGNED_URL_TTL        = "3600"
        CORS_ALLOW_ORIGINS       = "http://$($FrontendBucket).s3-website-$Region.amazonaws.com"
    }

    $functionExists = Test-AwsResourceExists -Arguments @("lambda", "get-function", "--function-name", $FunctionName)
    if (-not $functionExists) {
        Invoke-AwsCommand -Arguments @(
            "lambda", "create-function",
            "--function-name", $FunctionName,
            "--runtime", "python3.12",
            "--handler", "lambda_function.lambda_handler",
            "--role", $roleArn,
            "--timeout", "29",
            "--memory-size", "512",
            "--zip-file", "fileb://$zipPath",
            "--environment", (ConvertTo-Json @{ Variables = $envVars } -Compress)
        ) | Out-Null
    }
    else {
        Invoke-AwsCommand -Arguments @(
            "lambda", "update-function-code",
            "--function-name", $FunctionName,
            "--zip-file", "fileb://$zipPath"
        ) | Out-Null

        Invoke-AwsCommand -Arguments @(
            "lambda", "update-function-configuration",
            "--function-name", $FunctionName,
            "--runtime", "python3.12",
            "--handler", "lambda_function.lambda_handler",
            "--role", $roleArn,
            "--timeout", "29",
            "--memory-size", "512",
            "--environment", (ConvertTo-Json @{ Variables = $envVars } -Compress)
        ) | Out-Null
    }

    Invoke-AwsCommand -Arguments @("lambda", "wait", "function-updated", "--function-name", $FunctionName) | Out-Null

    return (Invoke-AwsJson -Arguments @("lambda", "get-function", "--function-name", $FunctionName)).Configuration.FunctionArn
}

function Ensure-HttpApi {
    param(
        [Parameter(Mandatory = $true)][string]$LambdaArn,
        [Parameter(Mandatory = $true)][string]$Account
    )

    $apis = Invoke-AwsJson -Arguments @("apigatewayv2", "get-apis")
    $api = $apis.Items | Where-Object { $_.Name -eq $ApiName } | Select-Object -First 1

    if (-not $api) {
        $api = Invoke-AwsJson -Arguments @(
            "apigatewayv2", "create-api",
            "--name", $ApiName,
            "--protocol-type", "HTTP"
        )
    }

    $apiId = $api.ApiId

    $integrations = Invoke-AwsJson -Arguments @("apigatewayv2", "get-integrations", "--api-id", $apiId)
    $integration = $integrations.Items | Where-Object { $_.IntegrationType -eq "AWS_PROXY" -and $_.IntegrationUri -eq $LambdaArn } | Select-Object -First 1

    if (-not $integration) {
        $integration = Invoke-AwsJson -Arguments @(
            "apigatewayv2", "create-integration",
            "--api-id", $apiId,
            "--integration-type", "AWS_PROXY",
            "--integration-uri", $LambdaArn,
            "--payload-format-version", "2.0"
        )
    }

    $routes = Get-Content $routesFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

    $existingRoutes = Invoke-AwsJson -Arguments @("apigatewayv2", "get-routes", "--api-id", $apiId)
    $existingRouteKeys = @{}
    foreach ($routeItem in $existingRoutes.Items) {
        $existingRouteKeys[$routeItem.RouteKey] = $true
    }

    foreach ($routeLine in $routes) {
        if ($routeLine -notmatch '^([A-Z]+)\s+(.+)$') {
            continue
        }

        $routeKey = "$($Matches[1]) $($Matches[2])"
        if ($existingRouteKeys.ContainsKey($routeKey)) {
            continue
        }

        Invoke-AwsCommand -Arguments @(
            "apigatewayv2", "create-route",
            "--api-id", $apiId,
            "--route-key", $routeKey,
            "--target", "integrations/$($integration.IntegrationId)"
        ) | Out-Null
    }

    $stages = Invoke-AwsJson -Arguments @("apigatewayv2", "get-stages", "--api-id", $apiId)
    $stage = $stages.Items | Where-Object { $_.StageName -eq $StageName } | Select-Object -First 1
    if (-not $stage) {
        Invoke-AwsCommand -Arguments @(
            "apigatewayv2", "create-stage",
            "--api-id", $apiId,
            "--stage-name", $StageName,
            "--auto-deploy"
        ) | Out-Null
    }
    else {
        Invoke-AwsCommand -Arguments @(
            "apigatewayv2", "update-stage",
            "--api-id", $apiId,
            "--stage-name", $StageName,
            "--auto-deploy"
        ) | Out-Null
    }

    $statementId = "AllowInvoke$ApiName".Replace("-", "")
    $sourceArn = "arn:aws:execute-api:${Region}:${Account}:$apiId/*/*/*"
    try {
        Invoke-AwsCommand -Arguments @(
            "lambda", "add-permission",
            "--function-name", $FunctionName,
            "--statement-id", $statementId,
            "--action", "lambda:InvokeFunction",
            "--principal", "apigateway.amazonaws.com",
            "--source-arn", $sourceArn
        ) | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch "ResourceConflictException") {
            throw
        }
    }

    $baseUrl = "https://$($apiId).execute-api.$Region.amazonaws.com/$StageName"
    $healthUrl = "$baseUrl/api/health"

    return [pscustomobject]@{
        ApiId     = $apiId
        BaseUrl   = $baseUrl
        HealthUrl = $healthUrl
    }
}

function Ensure-FrontendBucket {
    param(
        [Parameter(Mandatory = $true)][string]$ApiBaseUrl
    )

    if (-not $FrontendBucket) {
        $script:FrontendBucket = "lambdax-frontend-$AccountId-$Region"
    }

    $bucketExists = Test-AwsResourceExists -Arguments @("s3api", "head-bucket", "--bucket", $FrontendBucket)
    if (-not $bucketExists) {
        if ($Region -eq "us-east-1") {
            Invoke-AwsCommand -Arguments @("s3api", "create-bucket", "--bucket", $FrontendBucket) | Out-Null
        }
        else {
            Invoke-AwsCommand -Arguments @(
                "s3api", "create-bucket",
                "--bucket", $FrontendBucket,
                "--create-bucket-configuration", "LocationConstraint=$Region"
            ) | Out-Null
        }
    }

    Invoke-AwsCommand -Arguments @(
        "s3api", "put-public-access-block",
        "--bucket", $FrontendBucket,
        "--public-access-block-configuration", "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"
    ) | Out-Null

    Invoke-AwsCommand -Arguments @(
        "s3api", "put-bucket-website",
        "--bucket", $FrontendBucket,
        "--website-configuration", '{"IndexDocument":{"Suffix":"login.html"},"ErrorDocument":{"Key":"login.html"}}'
    ) | Out-Null

    $policy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadForStaticWebsite",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::$FrontendBucket/*"
    }
  ]
}
"@
    $policyPath = Join-Path $scriptDir ".frontend_bucket_policy.json"
    Set-Content -Path $policyPath -Value $policy -Encoding utf8
    try {
        Invoke-AwsCommand -Arguments @(
            "s3api", "put-bucket-policy",
            "--bucket", $FrontendBucket,
            "--policy", "file://$policyPath"
        ) | Out-Null
    }
    finally {
        if (Test-Path $policyPath) {
            Remove-Item -Force $policyPath
        }
    }

    if (-not $SkipFrontendUpload) {
        if (Test-Path $frontendBuildDir) {
            Remove-Item -Recurse -Force $frontendBuildDir
        }

        New-Item -ItemType Directory -Force -Path $frontendBuildDir | Out-Null
        Copy-Item -Path (Join-Path $frontendDir "*") -Destination $frontendBuildDir -Recurse -Force

        $configPath = Join-Path $frontendBuildDir "config.js"
        $configContents = @"
window.APP_CONFIG = {
  ARCHITECTURE: "Lambda",
  API_BASE_URL: "$ApiBaseUrl",
  ALLOW_HTTP_API: false,
  APP_TITLE: "MusicCloud Lambda"
};
"@
        Set-Content -Path $configPath -Value $configContents -Encoding utf8

        Invoke-AwsCommand -Arguments @(
            "s3", "sync",
            $frontendBuildDir,
            "s3://$FrontendBucket",
            "--delete"
        ) | Out-Null
    }

    return [pscustomobject]@{
        BucketName = $FrontendBucket
        WebsiteUrl = "http://$($FrontendBucket).s3-website-$Region.amazonaws.com"
    }
}

try {
    if (-not $Region) {
        throw "Region is required. Set -Region or AWS_REGION."
    }

    if (-not $AccountId) {
        $AccountId = Get-AwsCallerAccount
    }

    if (-not $FrontendBucket) {
        $FrontendBucket = "lambdax-frontend-$AccountId-$Region"
    }

    if (-not $PrivateBucket) {
        $PrivateBucket = "music-shared-private-covers-$AccountId-$Region"
    }

    Assert-Preconditions -TableNames @(
        "login",
        "music",
        "subscriptions"
    ) -BucketName $PrivateBucket -RoleName "LabRole"

    Write-Host "Packaging Lambda function..."
    Ensure-LambdaPackage

    Write-Host "Deploying Lambda function..."
    $lambdaArn = Ensure-LambdaFunction

    Write-Host "Deploying API Gateway..."
    $api = Ensure-HttpApi -LambdaArn $lambdaArn -Account $AccountId

    Write-Host "Deploying frontend bucket and site..."
    $frontend = Ensure-FrontendBucket -ApiBaseUrl $api.BaseUrl

    Write-Host "Verifying API health..."
    $healthResponse = Invoke-WebRequest -Uri $api.HealthUrl -Method Get
    if ($healthResponse.StatusCode -ne 200) {
        throw "Health check failed with status code $($healthResponse.StatusCode)."
    }

    Write-Host "Deployment complete."
    Write-Host "API Base URL: $($api.BaseUrl)"
    Write-Host "API Health URL: $($api.HealthUrl)"
    Write-Host "Frontend Website URL: $($frontend.WebsiteUrl)"
    Write-Host "Lambda Function: $FunctionName"
    Write-Host "Frontend Bucket: $($frontend.BucketName)"
}
finally {
    foreach ($path in @($buildDir, $frontendBuildDir)) {
        if (Test-Path $path) {
            Remove-Item -Recurse -Force $path
        }
    }
}