data "azurerm_client_config" "current" {}

terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm" }
    azapi   = { source = "azure/azapi" }
  }
}

provider "azurerm" {
  features {}
}

# ------------------------------------------------------------------------------------------------------
# Resource Group
# ------------------------------------------------------------------------------------------------------
data "azurerm_resource_group" "main" {
  name = "rg-${var.common.project}-${var.env}"
}

# ------------------------------------------------------------------------------------------------------
# Virtual Network
# ------------------------------------------------------------------------------------------------------
data "azurerm_virtual_network" "main" {
  name                = "vnet-${var.common.project}-${var.env}"
  resource_group_name = data.azurerm_resource_group.main.name
}

data "azurerm_subnet" "ci" {
  name                 = "snet-ci"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = data.azurerm_virtual_network.main.name
}

# ------------------------------------------------------------------------------------------------------
# User Assigned Managed ID
# ------------------------------------------------------------------------------------------------------
locals {
  role_assignment = [
    "Owner",
    "Key Vault Secrets Officer",
    "Storage Blob Data Contributor",
    "Storage File Data Privileged Contributor"
  ]
}

resource "azurerm_user_assigned_identity" "main" {
  name                = "id-ci-${var.common.project}-${var.env}"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
}

resource "azurerm_role_assignment" "main" {
  for_each             = toset(local.role_assignment)
  scope                = "/subscriptions/${data.azurerm_client_config.current.subscription_id}"
  role_definition_name = each.value
  principal_id         = azurerm_user_assigned_identity.main.principal_id
}

# ------------------------------------------------------------------------------------------------------
# Deployment Script
# ------------------------------------------------------------------------------------------------------
resource "azurerm_storage_account" "deploy_script" {
  name                     = "stds${var.common.project}${var.env}"
  resource_group_name      = data.azurerm_resource_group.main.name
  location                 = data.azurerm_resource_group.main.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  network_rules {
    bypass                     = ["AzureServices"]
    default_action             = "Deny"
    virtual_network_subnet_ids = [data.azurerm_subnet.ci.id]
    ip_rules                   = var.allowed_cidr
  }
}

resource "azapi_resource" "keyvault_secret_set" {
  type      = "Microsoft.Resources/deploymentScripts@2023-08-01"
  name      = "terraform-deploy-script"
  parent_id = data.azurerm_resource_group.main.id
  body = {
    kind     = "AzureCLI"
    location = data.azurerm_resource_group.main.location
    identity = {
      type = "userAssigned"
      userAssignedIdentities = {
        (azurerm_user_assigned_identity.main.id) = {}
      }
    }
    properties = {
      azCliVersion      = var.az_cli_version
      timeout           = "PT30M"        # スクリプトのタイムアウト時間 (ISO 8601 形式、例: PT30M は 30 分)
      retentionInterval = "PT1H"         # deploymentScript リソースを保持する期間 (ISO 8601 形式、例: PT1H は 1 時間、P1D は 1 日)
      cleanupPreference = "OnExpiration" # スクリプトの実行が終了状態になった時にサポートリソースをクリーンアップする方法 (Always, OnSuccess, OnExpiration)
      storageAccountSettings = {
        storageAccountName = azurerm_storage_account.deploy_script.name
      }
      containerSettings = {
        subnetIds = [
          { id = data.azurerm_subnet.ci.id, name = data.azurerm_subnet.ci.name }
        ]
      }
      environmentVariables = [
        {
          name = "ARM_SUBSCRIPTION_ID", value = data.azurerm_client_config.current.subscription_id
        },
        {
          name = "TF_VAR_allowed_cidr", value = jsonencode(var.allowed_cidr)
        },
        {
          name = "TF_VERSION", value = var.tf_version
        },
      ]
      scriptContent = <<BASH
        set -euo pipefail

        # --- 1) 事前ツールのインストール（Terraform） ---
        apk update >/dev/null
        apk add --no-cache unzip curl git >/dev/null

        echo "Installing terraform $${TF_VERSION} ..."
        curl -L -o /tmp/tf.zip https://releases.hashicorp.com/terraform/$${TF_VERSION}/terraform_$${TF_VERSION}_linux_amd64.zip >/dev/null
        unzip -o /tmp/tf.zip -d /usr/local/bin >/dev/null
        terraform -version

        # --- 2) コード取得（git clone） ---
        echo "Cloning repo..."
        workdir=/tmp/src
        git clone --depth=1 https://github.com/m-oka-system/azure-deployment-script.git /tmp/src >/dev/null
        cd /tmp/src/terraform

        # --- 3) init/plan/apply ---
        # Terraform init の実行と結果の取得
        echo "Running terraform init..."
        terraform init -no-color -input=false > /tmp/init_output.txt 2>&1
        INIT_EXIT_CODE=$?
        INIT_OUTPUT=$(cat /tmp/init_output.txt)

        # Terraform plan の実行と結果の取得
        echo "Running terraform plan..."
        if [ $INIT_EXIT_CODE -eq 0 ]; then
          terraform plan -no-color -input=false > /tmp/plan_output.txt 2>&1
          PLAN_EXIT_CODE=$?
          PLAN_OUTPUT=$(cat /tmp/plan_output.txt)
        else
          PLAN_OUTPUT="Skipped due to init failure"
          PLAN_EXIT_CODE=1
        fi

        # Terraform apply の実行と結果の取得
        echo "Running terraform apply..."
        if [ $PLAN_EXIT_CODE -eq 0 ]; then
          terraform apply -no-color -input=false -auto-approve > /tmp/apply_output.txt 2>&1
          APPLY_EXIT_CODE=$?
          APPLY_OUTPUT=$(cat /tmp/apply_output.txt)
        else
          APPLY_OUTPUT="Skipped due to plan failure"
          APPLY_EXIT_CODE=1
        fi

        # 結果をJSON形式で $AZ_SCRIPTS_OUTPUT_PATH に出力（整形版・改行対応）
        # planOutputとapplyOutputを行配列として分割して見やすくする
        jq -n --indent 2 \
          --arg subscription_id "$ARM_SUBSCRIPTION_ID" \
          --arg tf_version "$TF_VERSION" \
          --argjson init_exit_code "$INIT_EXIT_CODE" \
          --argjson plan_exit_code "$PLAN_EXIT_CODE" \
          --argjson apply_exit_code "$APPLY_EXIT_CODE" \
          --arg init_output "$INIT_OUTPUT" \
          --arg plan_output "$PLAN_OUTPUT" \
          --arg apply_output "$APPLY_OUTPUT" \
          --arg timestamp "$(TZ=Asia/Tokyo date -Iseconds)" \
          '{
            "terraformResults": {
              "subscriptionId": $subscription_id,
              "terraformVersion": $tf_version,
              "initExitCode": $init_exit_code,
              "planExitCode": $plan_exit_code,
              "applyExitCode": $apply_exit_code,
              "initOutputLines": ($init_output | split("\n")),
              "planOutputLines": ($plan_output | split("\n")),
              "applyOutputLines": ($apply_output | split("\n")),
              "timestamp": $timestamp
            }
          }' > $AZ_SCRIPTS_OUTPUT_PATH

        echo "Terraform execution completed. Results saved to $AZ_SCRIPTS_OUTPUT_PATH"

        # デバッグ用：出力ファイルの内容を表示
        cat $AZ_SCRIPTS_OUTPUT_PATH

        # 出力ディレクトリにも詳細ログを保存
        echo "$INIT_OUTPUT" > $AZ_SCRIPTS_PATH_OUTPUT_DIRECTORY/terraform-init.log
        echo "$PLAN_OUTPUT" > $AZ_SCRIPTS_PATH_OUTPUT_DIRECTORY/terraform-plan.log
        echo "$APPLY_OUTPUT" > $AZ_SCRIPTS_PATH_OUTPUT_DIRECTORY/terraform-apply.log
      BASH
    }
  }
}


# 2025/9 時点では azurerm プロバイダーではサブネットの指定ができない
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_deployment_script_azure_cli
# resource "azurerm_resource_deployment_script_azure_cli" "deploy_script" {
#   name                = "keyvault_secret_set"
#   resource_group_name = azurerm_resource_group.main.name
#   location            = azurerm_resource_group.main.location
#   version             = "2.52.0"
#   retention_interval  = "P1D"
#   cleanup_preference  = "OnSuccess"
#   timeout             = "PT5M"

#   scriptContent = <<EOF
#     set -e
#     echo "Starting Key Vault secret creation..."
#     %{for secret_name, secret_value in local.keyvault_secrets~}
#     echo "Checking if secret exists: ${secret_name}"
#     if ! az keyvault secret show --vault-name ${azurerm_key_vault.kv.name} --name ${secret_name} >/dev/null 2>&1; then
#       echo "Creating secret: ${secret_name}"
#       az keyvault secret set --vault-name ${azurerm_key_vault.kv.name} --name ${secret_name} --value "${secret_value}"
#     else
#       echo "Secret ${secret_name} already exists, skipping"
#     fi
#     %{endfor~}
#     echo "Secret creation process completed"
#   EOF

#   identity {
#     type = "UserAssigned"
#     identity_ids = [
#       azurerm_user_assigned_identity.id["ci"].id
#     ]
#   }
# }

# locals {
#   keyvault_secrets = {
#     "MySecretName1" = "MySecretValue1"
#     "MySecretName2" = "MySecretValue2"
#     "MySecretName3" = "MySecretValue3"
#   }
# }
