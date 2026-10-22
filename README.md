# AWS Proj-5: End-to-End CI/CD (Jenkins + Docker + EC2 + RDS + S3), built manually in the AWS Console

You will build the VPC from the Proj-5 diagram by hand, then run a Jenkins pipeline that
tests the code, builds a **Docker image** and pushes it to **Docker Hub**, migrates the
database, makes the web server **pull and run the image as a container**, smoke-tests it,
and ships build logs to S3.

## Architecture

Region: **Asia Pacific (Mumbai), `ap-south-1`**. Availability Zones used: `ap-south-1a` and `ap-south-1b`.

```
                         VPC 10.0.0.0/16
 ┌──────────────────────────────────────────────────────────────────────┐
 │  PUB-SUB 10.0.1.0/24          PUB-SUB 10.0.2.0/24                     │
 │  ┌──────────────────┐  SSH   ┌──────────────────┐                     │
 │  │ end-user host    │◀──────▶│ web server       │◀── HTTP :80 (internet)
 │  │ (bastion + NAT)  │        │ nginx + Docker   │                     │
 │  └───────┬──────────┘        └───────▲──────────┘                     │
 │          │ SSH                       │ SSH (deploy)                   │
 │          ▼                           │                                │
 │  PRI-SUB 10.0.11.0/24 ───────────────┘                                │
 │  ┌──────────────────┐   :3306   PRI-SUB 10.0.12.0/24 + 10.0.13.0/24   │
 │  │ Jenkins + Docker │──────────▶┌──────────────────┐                  │
 │  └───────┬──────────┘           │ RDS MySQL        │                  │
 │          │ IAM role             └──────────────────┘                  │
 └──────────┼───────────────────────────────────────────────────────────┘
            ▼
        S3 bucket (build logs)

 Image flow:  Jenkins --docker push--> Docker Hub --docker pull--> web server
              (via NAT)                                            (runs the container)
```

## Assumptions and deviations from the diagram

These are my interpretation of the sketch. Check them against your intent.

1. **"End-user" is an admin/bastion host.** It is your only way into the private Jenkins server. Public visitors reach the web server directly on port 80.
2. **RDS has no SSH.** The diagram's SSH links to the database are implemented as MySQL (port 3306).
3. **Two DB subnets, not one.** RDS requires a subnet group spanning two Availability Zones.
4. **A NAT gateway is added** so the private Jenkins host can reach the internet (Jenkins repo, plugins, GitHub, PyPI).
5. **Polling instead of webhooks.** Jenkins is private, so GitHub cannot call it; the job polls the repo about every 2 minutes.
6. **The two public-subnet servers can SSH to each other in both directions** (end-user host ↔ web server), using their private IPs. Jenkins can SSH to the web server only (needed for deployment).
7. **Docker Hub is the image registry.** Jenkins builds the image and pushes it; the web server pulls it. The repository is **public** (simplest): the image contains only code, never secrets. The database settings are supplied to the container at run time from `/etc/webapp.env`. If you make the repository private, run `sudo docker login` once on the web server.
8. **Brief downtime on each deploy.** The old container is stopped before the new one starts (a few seconds); if the new one is unhealthy, the old image is started again.

## Before you start

- AWS account, signed in to the Console. **Use the Asia Pacific (Mumbai) region, `ap-south-1`, for everything.** Check the region selector at the top right of the Console before creating each resource; resources created in different regions cannot see each other.
- An EC2 key pair (Console: EC2 → Key pairs → Create). Download the `.pem`.
- A Git repo (GitHub etc.) to push this project to.
- A **Docker Hub** account. Then, before Step 12:
  1. Docker Hub → Repositories → **Create repository**: name `proj5-webapp`, visibility **Public**.
  2. Account settings → Personal access tokens → **Generate new token** with **Read & Write** access. Copy it now (it is shown once). You will give this token to Jenkins instead of your password.
- Your public IP (search "what is my IP"). You'll allow SSH only from `<your-ip>/32`.

Keep this worksheet open and fill it in as you go:

| Value | Where it comes from | Yours |
|---|---|---|
| Bastion (end-user) public IP | Step 7 | |
| Bastion (end-user) private IP | Step 7 | |
| Web server private IP | Step 7 | |
| Web server public IP | Step 7 | |
| Jenkins private IP | Step 7 | |
| RDS endpoint | Step 6 | |
| DB master password | Step 6 | |
| S3 bucket name | Step 5 | |
| Docker Hub username | Your account | |
| Docker Hub access token (keep secret) | Prerequisites | |

---

## Part 1: Network

### Step 1. Create the VPC

VPC → Your VPCs → **Create VPC** → choose **VPC only**.
- Name: `proj5-vpc`
- IPv4 CIDR: `10.0.0.0/16`
- Create, then Actions → **Edit VPC settings** → tick **Enable DNS hostnames** → Save.

### Step 2. Create the five subnets

VPC → Subnets → **Create subnet**, VPC `proj5-vpc`. You can add all five in one go.

| Name | Availability Zone | IPv4 CIDR | Purpose |
|---|---|---|---|
| `proj5-pub-enduser` | `ap-south-1a` | `10.0.1.0/24` | Bastion + NAT gateway |
| `proj5-pub-web` | `ap-south-1b` | `10.0.2.0/24` | Web server |
| `proj5-pri-jenkins` | `ap-south-1a` | `10.0.11.0/24` | Jenkins |
| `proj5-pri-db-a` | `ap-south-1a` | `10.0.12.0/24` | RDS |
| `proj5-pri-db-b` | `ap-south-1b` | `10.0.13.0/24` | RDS (second AZ is mandatory) |

Use Availability Zones `ap-south-1a` and `ap-south-1b` (Mumbai also has `ap-south-1c`; it is not used here).

### Step 3. Internet gateway, NAT gateway, route tables

1. **Internet gateway:** VPC → Internet gateways → Create, name `proj5-igw` → Actions → **Attach to VPC** → `proj5-vpc`.
2. **NAT gateway:** VPC → NAT gateways → Create.
   - Name `proj5-nat`, subnet **`proj5-pub-enduser`** (it must be a *public* subnet), connectivity **Public**.
   - Click **Allocate Elastic IP**, then Create. (If the console asks for an availability mode, choose Zonal.)
   - Wait until the state is **Available** (a couple of minutes).
3. **Public route table:** VPC → Route tables → Create, name `proj5-public-rt`, VPC `proj5-vpc`.
   - Routes → Edit → Add route: `0.0.0.0/0` → target **Internet Gateway** `proj5-igw`.
   - Subnet associations → Edit → select `proj5-pub-enduser` and `proj5-pub-web`.
4. **Private route table:** Create `proj5-private-rt`, VPC `proj5-vpc`.
   - Add route: `0.0.0.0/0` → target **NAT Gateway** `proj5-nat`.
   - Subnet associations → select **only** `proj5-pri-jenkins`.
   - The two DB subnets stay on the VPC's main route table, which only has the local route. They have no internet access, which is what you want.

### Step 4. Security groups

EC2 → Security groups → Create. Use VPC `proj5-vpc` and leave outbound as the default (all traffic). **Create them in this order**, because later groups reference earlier ones.

| # | Name | Inbound rules |
|---|---|---|
| 1 | `proj5-bastion-sg` | SSH (22) from **My IP**; SSH (22) from `proj5-web-sg` (added last, see below) |
| 2 | `proj5-jenkins-sg` | SSH (22) from `proj5-bastion-sg` |
| 3 | `proj5-web-sg` | HTTP (80) from `0.0.0.0/0`; SSH (22) from `proj5-bastion-sg`; SSH (22) from `proj5-jenkins-sg` |
| 4 | `proj5-db-sg` | MYSQL/Aurora (3306) from `proj5-web-sg`; again from `proj5-jenkins-sg`; again from `proj5-bastion-sg` |

For the "from a security group" rules, set Source type to **Custom** and start typing the group name (or `sg-`) to pick it.

**Finish the bastion group last.** `proj5-bastion-sg` and `proj5-web-sg` allow SSH from each other, and a group can't reference one that doesn't exist yet. So create `proj5-bastion-sg` with only the My IP rule, create the other three groups, then go back to `proj5-bastion-sg` → Edit inbound rules → add SSH (22) from `proj5-web-sg`. This is what lets the two public servers SSH to each other (over their private IPs, so the traffic never leaves the VPC).

---

## Part 2: Storage and permissions

### Step 5. S3 bucket for build logs

S3 → Create bucket.
- Name: globally unique, e.g. `proj5-jenkins-logs-<yourname>-<4 random digits>`. Write it in the worksheet.
- Region: **Asia Pacific (Mumbai) `ap-south-1`**, same as everything else. Leave **Block all public access** ON and default encryption (SSE-S3) as is.
- Optional: Management → Lifecycle rule to expire objects after 90 days.

### Step 5b. IAM role for Jenkins (so no access keys are needed)

IAM → Roles → Create role.
- Trusted entity: **AWS service** → use case **EC2**.
- Skip attaching managed policies. Name the role `proj5-jenkins-role` and create it.
- Open the role → Add permissions → **Create inline policy** → JSON (replace `YOUR-BUCKET`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::YOUR-BUCKET"
    }
  ]
}
```

Name it `write-build-logs`. When you create a role for EC2 in the console, an instance profile with the same name is created automatically.

---

## Part 3: Database

### Step 6. RDS MySQL

1. **Subnet group:** RDS → Subnet groups → Create. Name `proj5-db-subnets`, VPC `proj5-vpc`, add both AZs, and select subnets `proj5-pri-db-a` and `proj5-pri-db-b`.
2. **Database:** RDS → Databases → Create database → **Standard create**.
   - Engine: **MySQL** (8.0.x). Template: **Free tier** or **Dev/Test**, **Single-AZ** instance.
   - DB instance identifier: `proj5-mysql`. Master username: `admin`.
   - Credentials management: **Self managed**. Set a master password of **12+ characters using only letters, digits and underscore** (the setup scripts reject other characters). Record it.
   - Instance class: `db.t3.micro` (burstable). Storage: 20 GiB gp3. Leave **Enable encryption** ticked (the console default).
   - Connectivity: VPC `proj5-vpc`, subnet group `proj5-db-subnets`, **Public access: No**, existing security group `proj5-db-sg` (remove `default`).
   - Expand **Additional configuration** and set **Initial database name** to `appdb`. If you skip this, the pipeline fails later with "Unknown database".
   - Create. This takes 5-10 minutes. Copy the **Endpoint** (a hostname) to the worksheet once it's Available.

---

## Part 4: Servers

### Step 7. Launch three EC2 instances

EC2 → Instances → **Launch instances**. Common settings: AMI **Amazon Linux 2023** (64-bit x86), your key pair, VPC `proj5-vpc`, "Select existing security group".

| Name | Instance type | Subnet | Auto-assign public IP | Security group | Other |
|---|---|---|---|---|---|
| `proj5-enduser` | `t3.micro` | `proj5-pub-enduser` | **Enable** | `proj5-bastion-sg` | |
| `proj5-web` | `t3.micro` | `proj5-pub-web` | **Enable** | `proj5-web-sg` | |
| `proj5-jenkins` | `t3.small` (Jenkins is sluggish on 1 GB RAM) | `proj5-pri-jenkins` | **Disable** | `proj5-jenkins-sg` | Storage 20 GiB gp3; Advanced details → **IAM instance profile** = `proj5-jenkins-role` |

When they're running, record in the worksheet: bastion public **and private** IPs, web **private** and public IPs, and Jenkins **private** IP.

If you forgot the IAM profile on Jenkins: select the instance → Actions → Security → **Modify IAM role**.

### Step 8. SSH access through the bastion

Jenkins and the web server only accept SSH from other servers, so you hop through the bastion. Put this in your SSH config (`~/.ssh/config`; on Windows `C:\Users\<you>\.ssh\config`), using your own IPs and key path:

```
Host proj5-bastion
    HostName <BASTION_PUBLIC_IP>
    User ec2-user
    IdentityFile ~/.ssh/my-key.pem
    ForwardAgent yes

Host proj5-web
    HostName <WEB_PRIVATE_IP>
    User ec2-user
    IdentityFile ~/.ssh/my-key.pem
    ProxyJump proj5-bastion
    ForwardAgent yes

Host proj5-jenkins
    HostName <JENKINS_PRIVATE_IP>
    User ec2-user
    IdentityFile ~/.ssh/my-key.pem
    ProxyJump proj5-bastion
    LocalForward 8080 localhost:8080
```

`LocalForward` makes `http://localhost:8080` on your laptop show the Jenkins UI while an `ssh proj5-jenkins` session is open.

Key file permissions: Linux/macOS `chmod 400 my-key.pem`. Windows, if you get "UNPROTECTED PRIVATE KEY FILE": 
`icacls my-key.pem /inheritance:r` then `icacls my-key.pem /grant:r "%username%:R"`.

`ForwardAgent yes` lets the bastion and the web server SSH onward using the key held on your laptop, so the `.pem` is never copied onto a server. It needs the key loaded into your local SSH agent:

- **Linux/macOS:** `eval "$(ssh-agent -s)"` then `ssh-add ~/.ssh/my-key.pem`
- **Windows (PowerShell as Administrator, once):** `Set-Service ssh-agent -StartupType Manual` then `Start-Service ssh-agent`. Then, as a normal user: `ssh-add $HOME\.ssh\my-key.pem`

Check with `ssh-add -l` (it should list your key). Test the first hop: `ssh proj5-bastion`, then `exit`.

### Step 8b. Verify SSH between the two public servers

```bash
ssh proj5-bastion                              # laptop -> end-user host
ssh ec2-user@<WEB_PRIVATE_IP> hostname         # end-user host -> web server (type "yes" to the host-key prompt)
exit

ssh proj5-web                                  # laptop -> web server (via the end-user host)
ssh ec2-user@<BASTION_PRIVATE_IP> hostname     # web server -> end-user host
exit
```

Each inner command should print the other server's hostname. Both directions must work.

### Step 9. Configure the bastion (optional DB client)

```bash
ssh proj5-bastion
sudo dnf install -y mariadb105
mysql -h <RDS_ENDPOINT> -u admin -p -e "SHOW DATABASES;"   # should list appdb
exit
```

If this hangs, check `proj5-db-sg` allows 3306 from `proj5-bastion-sg`. If it connects but `appdb` is missing, run `CREATE DATABASE appdb;`.

### Step 10. Configure the web server

From your laptop, in the project folder:

```bash
scp scripts/setup_web.sh proj5-web:~
ssh proj5-web
sudo bash setup_web.sh        # prompts: RDS endpoint, DB user, DB name, DB password
```

It installs Docker and nginx, writes the database settings to `/etc/webapp.env` (readable only by root, passed to the container at run time), and starts nginx as a reverse proxy to `127.0.0.1:8000`. The application is **not** installed here: the first pipeline run pulls the image from Docker Hub and starts the container. A 502 page from the web server's public IP is **expected** until then.

### Step 11. Configure the Jenkins server

```bash
scp scripts/setup_jenkins.sh proj5-jenkins:~
ssh proj5-jenkins
sudo bash setup_jenkins.sh    # prompts: web private IP, RDS endpoint, DB user/name, S3 bucket, Docker Hub username
```

It installs Docker, Java 21 and Jenkins (LTS repo), lets the `jenkins` user run Docker, records the settings the pipeline reads (including your Docker Hub username), and checks the IAM role can reach your bucket. If the check warns, fix the role or bucket name before continuing.

Keep this SSH session open (it holds the tunnel) and print the unlock password:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

---

## Part 5: Jenkins and the pipeline

### Step 12. Configure Jenkins

1. Browse to **http://localhost:8080** (tunnel from Step 8), paste the password, choose **Install suggested plugins**, create your admin user.
2. Manage Jenkins → Plugins → Available → install **SSH Agent**.
3. Manage Jenkins → Nodes → Built-In Node → Configure: set **Number of executors** to at least 1.
4. Manage Jenkins → Credentials → System → Global → Add credentials:
   - Kind **Secret text**, ID `db-password`, Secret = your RDS master password.
   - Kind **SSH Username with private key**, ID `web-ssh-key`, Username `ec2-user`, Private key → Enter directly → paste the full contents of your `.pem`.
   - Kind **Secret text**, ID `dockerhub-token`, Secret = your Docker Hub **access token** (not your account password).
5. New Item → name `proj5` → **Pipeline** → Pipeline definition **Pipeline script from SCM** → Git → your repo URL (add a credential if the repo is private), branch `*/main`, script path `Jenkinsfile`.

### Step 13. Push the code and run

```bash
git init && git add . && git commit -m "AWS Proj-5 CI/CD"
git branch -M main && git remote add origin <your-repo-url> && git push -u origin main
```

In Jenkins click **Build Now**. Later commits are picked up by polling.

### Step 14. Verify

- `http://<web public IP>` shows the app, "Hello from RDS", and the build version.
- `http://<web public IP>/health` returns JSON with the version; `/db-check` returns `{"database":"up"}`.
- Docker Hub: your `proj5-webapp` repository → Tags shows `latest` and a tag like `1-ab12cd3` (build number and commit).
- On the web server (`ssh proj5-web`): `sudo docker ps` shows the `webapp` container as `Up ... (healthy)` with the same tag, and `sudo docker logs webapp` shows gunicorn output.
- Logs in S3: from the Jenkins SSH session run `aws s3 ls s3://<bucket>/ --recursive`. Each build has `build-summary.txt`, `junit.xml` and `console.log`.
- Make a visible change in `app/app.py` (e.g. the heading), push, and watch Jenkins build a new image, push it and replace the container within a couple of minutes.

## Pipeline stages

| Stage | What happens |
|---|---|
| Lint & Test | venv, `flake8`, `pytest` (JUnit results published) |
| Build Image | Logs in to Docker Hub, `docker build` using the `Dockerfile`, tags `<user>/proj5-webapp:<build>-<commit>` and `:latest` |
| Push Image | `docker push` both tags to Docker Hub |
| DB Migrate | Applies `db/schema.sql` to RDS from Jenkins (idempotent) |
| Deploy | Copies `deploy.sh` to the web server and runs it over SSH: `docker pull`, replace the `webapp` container, health check; a failed health check restarts the previous image |
| Smoke Test | Polls `/health` until it reports the new version |
| Post (always) | Logs out of Docker Hub, prunes old images, uploads build summary, test report and console log to S3 |

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Build stuck "Waiting for next available executor" | Built-In Node has 0 executors (Step 12.3) |
| `Unknown database 'appdb'` in DB Migrate | Initial database name was skipped; run `CREATE DATABASE appdb;` from the bastion |
| DB Migrate hangs/times out | `proj5-db-sg` missing the 3306 rule from `proj5-jenkins-sg` |
| `Permission denied (publickey)` in Deploy | `web-ssh-key` credential: wrong username (must be `ec2-user`) or wrong key |
| Deploy times out connecting | `proj5-web-sg` missing the SSH rule from `proj5-jenkins-sg`, or wrong `WEB_HOST` |
| `AccessDenied` on `aws s3 cp` | IAM role not attached to Jenkins, or the policy bucket name is wrong |
| Jenkins can't download plugins/clone repo | Private route table lacks the NAT route, or NAT isn't Available |
| `Permission denied (publickey)` between the two public servers | Agent not forwarded: run `ssh-add -l` on your laptop and again on the first server; it must list your key (Step 8) |
| Timeout between the two public servers | Missing SSH rule: `proj5-bastion-sg` must allow 22 from `proj5-web-sg`, and `proj5-web-sg` must allow 22 from `proj5-bastion-sg`; use private IPs |
| Web server shows 502 after a deploy | `sudo docker ps -a` and `sudo docker logs webapp` on the web server (usually wrong DB settings in `/etc/webapp.env`, or the container exited) |
| `permission denied ... docker.sock` in Jenkins | The `jenkins` user is not in the `docker` group yet: `sudo usermod -aG docker jenkins && sudo systemctl restart jenkins` |
| `denied: requested access to the resource is denied` on Push Image | Wrong Docker Hub username in the Jenkins settings, token without Write access, or repository name is not `proj5-webapp` |
| `unauthorized` / `incorrect username or password` on login | `dockerhub-token` credential must contain the access token, and `DOCKERHUB_USER` must be your username (not email) |
| `pull access denied` or `repository does not exist` on the web server | The Docker Hub repository is private (make it public or run `sudo docker login` on the web server) or the name is wrong |
| `toomanyrequests` | Docker Hub pull rate limit reached; wait and retry, or log in on the web server (`sudo docker login`) |
| Jenkins build runs out of disk | `docker system df` on Jenkins; `docker image prune -af` |
| Changed a Jenkins setting (e.g. DB host) | Edit `/etc/systemd/system/jenkins.service.d/override.conf`, then `sudo systemctl daemon-reload && sudo systemctl restart jenkins` |

## Cleanup (avoid charges)

The NAT gateway, RDS instance and EC2 instances bill while they exist. Delete in this order:

1. Terminate the three EC2 instances.
2. RDS: delete `proj5-mysql` (untick final snapshot for a lab), then the subnet group.
3. NAT gateway: delete it, wait until Deleted, then release its Elastic IP (EC2 → Elastic IPs).
4. S3: empty then delete the bucket. (Optional: delete the `proj5-webapp` repository and revoke the access token in Docker Hub.)
5. IAM: delete `proj5-jenkins-role`.
6. VPC: delete security groups, then the VPC itself (the console offers to remove the attached subnets, route tables and internet gateway).

## Known limitations

- **Not tested on real AWS.** I could not launch instances or run Jenkins here. The app and tests were exercised locally with stubbed dependencies, and the shell scripts were only syntax-checked. Console labels and layouts change over time, so a button or field may be named slightly differently.
- **Agent forwarding:** while you're connected, a root user on an intermediate server could use your forwarded key. Acceptable for a lab; for production prefer AWS Systems Manager Session Manager or per-host keys.
- **Secrets:** the DB password is stored in `/etc/webapp.env` on the web server (root-only). For anything beyond a lab, use AWS Secrets Manager or SSM Parameter Store. The Docker Hub token lives in the Jenkins credential store.
- **Public image:** anyone can pull `<user>/proj5-webapp`. That is safe here because the image contains no secrets, but do not put credentials or private data in the image.
- **Docker Hub limits:** Docker applies hourly pull limits to anonymous and free accounts (recent announcements describe about 10 anonymous and 100 authenticated pulls per hour; confirm current figures in Docker's documentation). Jenkins logs in before pulling the base image; the web server pulls once per deploy.
- **Not zero-downtime:** the container is replaced in place, so the site is briefly unavailable (seconds) during a deploy.
- The S3 console log is copied while the build is still finishing, so its last few lines may be missing. The log path assumes a plain (non-folder) Pipeline job.
- The web server is HTTP-only. Add an ALB with ACM/HTTPS for real traffic.
- Jenkins install details follow the current jenkins.io Linux docs (Java 21, `rpm-stable` repo). Re-check them if Jenkins changes its requirements.
