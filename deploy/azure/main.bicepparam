// Every value comes from the environment, so secrets never land in this file
// or on a command line. deploy.sh exports them from ../../.env.
using './main.bicep'

param appName = readEnvironmentVariable('AZURE_APP_NAME', 'kt-mcp')
param image = readEnvironmentVariable('IMAGE', '')
param registryUsername = readEnvironmentVariable('GHCR_USERNAME', '')
param registryPassword = readEnvironmentVariable('GHCR_TOKEN', '')
param publicUrl = readEnvironmentVariable('AZURE_PUBLIC_URL', '')

param ktEmail = readEnvironmentVariable('KT_EMAIL')
param ktPassword = readEnvironmentVariable('KT_PASSWORD')
param mcpAuthPassword = readEnvironmentVariable('MCP_AUTH_PASSWORD')
