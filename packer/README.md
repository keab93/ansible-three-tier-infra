# Golden image build

Builds the golden image with Packer on the Hyper-V host: an unattended Ubuntu Server 24.04 install, updated and sealed, as `output/Virtual Hard Disks/ubuntu-base.vhdx`.

1. Install Packer and add it to PATH.
2. Copy `http/user-data.example` to `http/user-data` and replace the password with a SHA-512 hash (`mkpasswd -m sha-512` on Linux). The password itself must not contain quotes.
3. Let the VM reach Packer's file server:
   ```powershell
   New-NetFirewallRule -DisplayName "Packer HTTP" -Direction Inbound -Protocol TCP -LocalPort 8800 -Action Allow
   ```
4. Build, in an elevated PowerShell in this folder:
   ```powershell
   $env:PKR_VAR_ssh_password = "<the password>"
   packer init .
   packer validate .
   packer build .
   ```
5. Copy the VHDX to Hyper-V's disk folder as `base.vhdx` and make it read-only.

The image is sealed when it shuts down: `/etc/machine-id` is emptied and the SSH host keys are removed, so the clone procedure in [ARCHITECTURE.md](../ARCHITECTURE.md#golden-image) generates new ones. cloud-init is disabled so clones don't re-run first-boot setup. `linux-cloud-tools-virtual` reports the VM's address to Hyper-V, which Packer needs to find the VM.
