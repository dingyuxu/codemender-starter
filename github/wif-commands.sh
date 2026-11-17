#!/usr/bin/env bash
# Prints the gcloud commands that let GitHub Actions sign in to Google Cloud with
# Workload Identity Federation. The commands come from the public documentation
# ("Integrate with CI/CD" > "Set up Workload Identity Federation").
#
# This script only prints. A Google Cloud project administrator should review the
# commands and run them. Roles needed to run them: Service Account Admin,
# Project IAM Admin, and Workload Identity Pool Admin.
#
# Usage: bash wif-commands.sh <project ID> <GitHub organization or user> <repository name>
set -uo pipefail

if [ $# -ne 3 ]; then
  echo "Usage: bash $0 <project ID> <GitHub organization or user> <repository name>" >&2
  exit 2
fi

PROJECT_ID="$1"
GITHUB_ORG="$2"
REPO="$2/$3"
SA="codemender-ci@${PROJECT_ID}.iam.gserviceaccount.com"

cat <<EOF
# 1. Enable the APIs that Workload Identity Federation uses
gcloud services enable iam.googleapis.com \\
    cloudresourcemanager.googleapis.com iamcredentials.googleapis.com \\
    sts.googleapis.com --project="${PROJECT_ID}"

# 2. Create a service account for the workflow and grant it roles/aiplatform.user
gcloud iam service-accounts create codemender-ci \\
    --project="${PROJECT_ID}" \\
    --display-name="CodeMender CI"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \\
    --member="serviceAccount:${SA}" \\
    --role="roles/aiplatform.user"

# 3. Create a workload identity pool. If you already have a pool for GitHub Actions,
#    skip this step and use your pool's ID instead of "github" in the commands below.
gcloud iam workload-identity-pools create github \\
    --project="${PROJECT_ID}" \\
    --location="global" \\
    --display-name="GitHub Actions"

# 4. Create a provider for GitHub in the pool. It accepts tokens only from
#    repositories that ${GITHUB_ORG} owns.
gcloud iam workload-identity-pools providers create-oidc codemender \\
    --project="${PROJECT_ID}" \\
    --location="global" \\
    --workload-identity-pool="github" \\
    --display-name="CodeMender" \\
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \\
    --attribute-condition="assertion.repository_owner == '${GITHUB_ORG}'" \\
    --issuer-uri="https://token.actions.githubusercontent.com"

# 5. Let workflows in ${REPO} use the service account
POOL_ID=\$(gcloud iam workload-identity-pools describe github \\
    --project="${PROJECT_ID}" \\
    --location="global" \\
    --format="value(name)")

gcloud iam service-accounts add-iam-policy-binding "${SA}" \\
    --project="${PROJECT_ID}" \\
    --role="roles/iam.workloadIdentityUser" \\
    --member="principalSet://iam.googleapis.com/\${POOL_ID}/attribute.repository/${REPO}"

# 6. Get the provider's full name. You need it in the next step.
gcloud iam workload-identity-pools providers describe codemender \\
    --project="${PROJECT_ID}" \\
    --location="global" \\
    --workload-identity-pool="github" \\
    --format="value(name)"

# Then add three secrets in the GitHub repository under
# Settings > Secrets and variables > Actions:
#   GCP_PROJECT_ID           ${PROJECT_ID}
#   GCP_WIF_PROVIDER         the name printed by step 6; it looks like
#                            projects/123456789/locations/global/workloadIdentityPools/github/providers/codemender
#   GCP_WIF_SERVICE_ACCOUNT  ${SA}
# Permission changes can take up to 5 minutes to take effect.
EOF
