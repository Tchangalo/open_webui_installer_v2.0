This script essentially executes the following commands:

## Uninstall Docker

Remove existing Docker installation, if present:

```bash
sudo apt-get update -y
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
sudo apt-get autoremove -y || true
sudo rm -rf /var/lib/docker /var/lib/containerd || true
sudo rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose || true
```

## Install Docker

Install dependencies:

```bash
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg lsb-release
```

Install Docker via the official script:

```bash
CHANNEL=stable
sudo bash -c "CHANNEL=${CHANNEL} && curl -fsSL https://get.docker.com | sh"
```

Enable/start Docker:

```bash
sudo systemctl enable --now docker
```

Add user to docker group:

```bash
sudo usermod -aG docker <username>
```

## Install Docker Compose

Remove existing docker-compose, if present:

```bash
sudo rm -f /usr/local/bin/docker-compose
```

Install docker-compose (latest release is fetched automatically).
Determine latest release URL and tag:

```bash
LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/docker/compose/releases/latest)"
LATEST_TAG="${LATEST_URL##*/}"
DOWNLOAD_URL="https://github.com/docker/compose/releases/download/${LATEST_TAG}/docker-compose-$(uname -s)-$(uname -m)"
```

Download into a temporary file (COMPOSE_TMP):

```bash
curl -fSL "${DOWNLOAD_URL}" -o /tmp/docker-compose.$$
```
Move file and make it executable:

```bash
sudo mv /tmp/docker-compose.$$ /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

Verify installation:

```
sudo /usr/local/bin/docker-compose version
```

## Fix for Portainer on Docker 29

Create override file:
```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
```

Create a temporary file and insert content:

```bash
TMP="$(mktemp)"
cat > "${TMP}" <<'EOF'
[Service]
Environment=DOCKER_MIN_API_VERSION=1.24
EOF
```

Move the override file, set permissions, reload systemd, and restart Docker:

```bash
sudo mv "${TMP}" /etc/systemd/system/docker.service.d/override.conf
sudo chmod 644 /etc/systemd/system/docker.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart docker
```

## Set up Portainer

Remove existing Portainer container, if present:

```bash
sudo docker rm -f portainer || true
```

Check if the volume exists:

```bash
docker volume ls --format '{{.Name}}' | grep -x 'portainer_data' >/dev/null 2>&1
``` 

Remove the volume if it exists:
IMPORTANT: If you want to keep your Data, comment this out in the script!

```bash
docker volume rm 'portainer_data' || true
```

Create Portainer volume:

```bash
sudo docker volume create portainer_data >/dev/null
``` 

Start Portainer container:

```bash
sudo docker run -d \
  -p 8000:8000 -p 9000:9000 \
  --name "portainer" \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "portainer_data:/data" \
  "portainer/portainer-ce"
```

## Set up Open WebUI

Remove existing Open WebUI container, if present:

```bash
sudo docker rm -f open-webui || true
```

Check if the ollama and the WebUI volumes exist:

```bash
docker volume ls --format '{{.Name}}' | grep -x 'ollama' >/dev/null 2>&1
docker volume ls --format '{{.Name}}' | grep -x 'open-webui' >/dev/null 2>&1
```

Remove the ollama and the Open WebUI volumes, if they exist: 
IMPORTANT: If you want to keep your Data/Modells, comment this out in the script.

```bash
docker volume rm 'ollama' || true
docker volume rm 'open-webui' || true
```

Create required volumes:

```bash
sudo docker volume create ollama >/dev/null || true
sudo docker volume create open-webui >/dev/null || true
```

Start Open WebUI container:

```bash
sudo docker run -d \
  -p 3000:8080 \
  -v ollama:/root/.ollama \
  -v open-webui:/app/backend/data \
  --name open-webui \
  --restart always \
  ghcr.io/open-webui/open-webui:ollama
```

Reboot:

```bash
sudo reboot
```

---

## Warning and Target Groups

Anyone who simply runs the script without understanding the process will not know what is happening. Therefore, the first installation should be done manually by entering the commands into the terminal one by one. This ensures you see exactly what happens. Once you are familiar with Open WebUI and no longer want to spend time on manual (re-)installations, the script becomes a useful helper.

Second, the script is for anyone who failed while performing a manual installation.

Third, it can be interesting to see how the commands listed above can be packaged into a Bash script.

---

## System Requirements

Tested on:

* Debian 13.2
* Ubuntu Server 24.0.3
* Mint 21.3, 22.1, 22.2

So it should also work on Ubuntu derivatives (Linux Lite, PopOS, etc.) and Debian derivatives (ParrotOS, Kali, etc.).

Especially Debian 13 requires the following adjustments:

1. Comment out the CD-ROM entry in `/etc/apt/sources.list`:

```text
#deb cdrom:[Debian GNU/Linux 13.1.0 _Trixie_ ...]/ trixie contrib main non-free-firmware
```

2. Log in as root and install sudo:

```bash
apt-get update
apt install -y sudo
```

3. Add user to sudo group:

```bash
usermod -aG sudo <username>
```

The script should run without changes on all Debian-based systems, I guess.

---

## Quickstart

1. Copy `setup_webui.sh` to the home directory of the user, e.g:

```bash
scp setup_webui.sh <username>@<server-ip>:/home/<username>
```

2. Make executable:

```bash
sudo chmod +x setup_webui.sh
```

3. Run the script:

```bash
./setup_webui.sh
```

Portainer is accessible in the browser at `<server-ip>:9000`, where an admin account must be created immediately.
Open WebUI is accessible at `<server-ip>:3000`. The first startup of the Open WebUI container may take several minutes. With any subsequent reboots or boots it should jump quickly to ```healthy```.

### GPU Support

Add the following flag to the Docker run command in Open WebUI section:

```
--gpus all
```
Like this:
```bash
${SUDO} docker run -d \
    -p 3000:8080 \
    -v ollama:/root/.ollama \
    -v open-webui:/app/backend/data \
    --gpus all \
    --name open-webui \
    --restart always \
    ghcr.io/open-webui/open-webui:ollama
succ "Open-WebUI running on port 3000 with GPU support."
```
---

## New Features of open_webui_installer_v2.0

While _open_webui_installer_v1.0_ simply installs/sets up the four modules Docker, Docker Compose, Portainer and Open WebUI one after another, _open_webui_installer_v2.0_ prompts the user for the action to be executed and the modules:

1. Do you want to _install_ or _remove_?
2. Which _module(s)_ do you want to install (or remove)?

Additionally, a summary of the current status of the four modules is provided at both the beginning and (eventually) the end of the script run.

_open_webui_installer_v2.0_ is therefore also suitable for quickly installing one or more modules in a convenient way as part of other projects.

If you choose the action ```ìnstall```, the choosen modules will be automatically removed before reinstallation, if they already exist.

Of course, users need to think carefully about their actions: for example, if someone tries to stop Portainer while Docker is not installed, an error message will naturally appear.

---

## Troubleshooting

Due to the compatibility fix, Portainer will be ```running``` but not ```healthy```.
Functionally it works; to have it ```healthy```, use Docker 28 and comment out the fix in the script.

On the very first start, eventually the open-webui container needs to be restarted again, or you may even need to perform a reboot, to jump to ```healthy```. The loading glitches of the Open WebUI container occur only when a new image is pulled — that is, when Docker has been freshly installed. If an image is already present, the container quickly switches to ```healthy```.
