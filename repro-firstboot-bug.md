# Repro: systemd ENABLE_ONLY first-boot preset bug on ACL

## Prerequisites
- ACL base image: `/subscriptions/035db282-f1c8-4ce7-b78f-2a7265d5398c/resourceGroups/acl/providers/Microsoft.Compute/galleries/acldevel/images/acldevel/versions/0.20260330.1082615`

## 1. Create VM
```bash
az vm create --resource-group aadagarwal --name acl-base-vm \
  --image /subscriptions/035db282-f1c8-4ce7-b78f-2a7265d5398c/resourceGroups/acl/providers/Microsoft.Compute/galleries/acldevel/images/acldevel/versions/0.20260330.1082615 \
  --generate-ssh-keys --size Standard_D2ds_v5 --location westus3 \
  --security-type TrustedLaunch --enable-vtpm true --public-ip-sku Standard
```

## 2. Drop a service file and remove machine-id
```bash
az vm run-command invoke --resource-group aadagarwal --name acl-base-vm \
  --command-id RunShellScript --scripts '
cat > /etc/systemd/system/test-autostart.service << EOF
[Unit]
Description=Test service

[Service]
Type=oneshot
ExecStart=/bin/echo "THIS SHOULD NOT RUN"

[Install]
WantedBy=multi-user.target
EOF

echo "is-enabled: $(systemctl is-enabled test-autostart.service 2>&1)"
rm -f /etc/machine-id
echo "machine-id removed"
'
```
Expected: `is-enabled: disabled`

## 3. Reboot
```bash
az vm restart --resource-group aadagarwal --name acl-base-vm
```

## 4. Verify
```bash
az vm run-command invoke --resource-group aadagarwal --name acl-base-vm \
  --command-id RunShellScript --scripts '
journalctl -b | grep -i "Detected first boot"
echo "is-enabled: $(systemctl is-enabled test-autostart.service 2>&1)"
ls -la /etc/systemd/system/multi-user.target.wants/test-autostart.service 2>&1
'
```
Expected:
- `Detected first boot.` — first boot triggered
- `is-enabled: enabled` — **bug**: service auto-enabled despite `disable *` preset
- symlink created at `multi-user.target.wants/test-autostart.service`

## 5. Show that FULL mode fixes it
```bash
az vm run-command invoke --resource-group aadagarwal --name acl-base-vm \
  --command-id RunShellScript --scripts '
systemctl preset-all --preset-mode=full --no-reload
echo "is-enabled: $(systemctl is-enabled test-autostart.service 2>&1)"
'
```
Expected: `is-enabled: disabled` — `disable *` correctly applied in FULL mode

## Root cause
systemd 255 on ACL runs `manager_preset_all()` in `ENABLE_ONLY` mode (`-Dfirst-boot-full-preset=false`), which ignores `disable` rules including `disable *` in `99-default-disable.preset`.

## Cleanup
```bash
az vm delete --resource-group aadagarwal --name acl-base-vm --yes
```
