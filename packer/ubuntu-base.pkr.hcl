packer {
  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = ">= 1.1.0"
    }
  }
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

source "hyperv-iso" "ubuntu" {
  iso_url            = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso"
  iso_checksum       = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
  generation         = 2
  enable_secure_boot = false
  switch_name        = "VS1"
  cpus               = 2
  memory             = 2048
  disk_size          = 65536
  http_directory     = "http"
  http_port_min      = 8800
  http_port_max      = 8800
  boot_wait          = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]
  communicator     = "ssh"
  ssh_username     = "cm"
  ssh_password     = var.ssh_password
  ssh_timeout      = "45m"
  shutdown_command = "echo '${var.ssh_password}' | sudo -S sh -c 'truncate -s 0 /etc/machine-id && rm -f /etc/ssh/ssh_host_* && shutdown -P now'"
  vm_name          = "ubuntu-base"
  output_directory = "output"
}

build {
  sources = ["source.hyperv-iso.ubuntu"]

  provisioner "shell" {
    execute_command = "echo '${var.ssh_password}' | sudo -S -E sh -eux '{{ .Path }}'"
    inline = [
      "apt-get update",
      "DEBIAN_FRONTEND=noninteractive apt-get -y upgrade",
      "touch /etc/cloud/cloud-init.disabled"
    ]
  }
}
