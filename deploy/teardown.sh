#!/usr/bin/env bash
# Removes EVERYTHING Maminco created in AWS (tag Project=maminco) and verifies nothing is left.
# Irreversible: data volume, media bucket and the database are deleted. Run from your workstation.
set -euo pipefail
cd "$(dirname "$0")/../terraform"
PROJECT="${PROJECT:-maminco}"
read -r -p "Type DELETE-${PROJECT} to destroy all ${PROJECT} resources: " ok
[ "$ok" = "DELETE-${PROJECT}" ] || { echo "aborted"; exit 1; }
cp main.tf main.tf.bak
trap 'mv main.tf.bak main.tf' EXIT
sed -i.tmp 's/prevent_destroy = true/prevent_destroy = false/' main.tf && rm -f main.tf.tmp
terraform apply -auto-approve -input=false -refresh=true >/dev/null
terraform destroy -auto-approve -input=false
echo "Remaining resources tagged Project=${PROJECT}:"
aws resourcegroupstaggingapi get-resources --tag-filters "Key=Project,Values=${PROJECT}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
