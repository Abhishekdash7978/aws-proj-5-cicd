#!/usr/bin/env bash
# One-time bootstrap for the JENKINS SERVER (Amazon Linux 2023).
# Installs Jenkins and Docker (the pipeline builds the app image on this server).
# Usage:  sudo bash setup_jenkins.sh    (prompts for the values the Jenkinsfile needs)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0" >&2
  exit 1
fi

check() {  # check <label> <value>
  if [[ ! "$2" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid $1: only letters, digits and . _ - are allowed." >&2
    exit 1
  fi
}

read -r -p "Web server PRIVATE IP (e.g. 10.0.2.15): " WEB_HOST
read -r -p "RDS endpoint: " DB_HOST
read -r -p "DB username [admin]: " DB_USER
read -r -p "DB name [appdb]: " DB_NAME
read -r -p "S3 log bucket name: " LOG_BUCKET
read -r -p "Docker Hub username: " DOCKERHUB_USER
DB_USER="${DB_USER:-admin}"
DB_NAME="${DB_NAME:-appdb}"

# Region from instance metadata (IMDSv2).
TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' || true)"
REGION="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region || true)"
if [ -z "$REGION" ]; then
  read -r -p "AWS region (e.g. ap-south-1): " REGION
fi

for pair in "web IP:$WEB_HOST" "DB endpoint:$DB_HOST" "DB user:$DB_USER" \
            "DB name:$DB_NAME" "bucket:$LOG_BUCKET" "Docker Hub user:$DOCKERHUB_USER" "region:$REGION"; do
  check "${pair%%:*}" "${pair#*:}"
done

# Jenkins documents Java 21 and the rpm-stable (LTS) repository.
dnf install -y java-21-amazon-corretto-headless fontconfig git python3 python3-pip tar mariadb105 docker
systemctl enable --now docker
curl -fsSL -o /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/rpm-stable/jenkins.repo
dnf install -y jenkins

# Let the jenkins user talk to the Docker daemon (takes effect when Jenkins starts below).
usermod -aG docker jenkins

# Values the Jenkinsfile reads from the environment.
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="WEB_HOST=$WEB_HOST"
Environment="DB_HOST=$DB_HOST"
Environment="DB_USER=$DB_USER"
Environment="DB_NAME=$DB_NAME"
Environment="LOG_BUCKET=$LOG_BUCKET"
Environment="DOCKERHUB_USER=$DOCKERHUB_USER"
Environment="AWS_DEFAULT_REGION=$REGION"
EOF

systemctl daemon-reload
systemctl enable --now jenkins

echo
echo "Checking the IAM role can reach the log bucket..."
if command -v aws >/dev/null && AWS_DEFAULT_REGION="$REGION" aws s3 ls "s3://$LOG_BUCKET" >/dev/null; then
  echo "OK: S3 access works."
else
  echo "WARNING: could not list s3://$LOG_BUCKET. Attach the IAM role to this instance" >&2
  echo "         (EC2 > Actions > Security > Modify IAM role) and check the bucket name." >&2
fi
echo "Jenkins is starting. Initial admin password:"
echo "  sudo cat /var/lib/jenkins/secrets/initialAdminPassword   (available after ~1 minute)"
