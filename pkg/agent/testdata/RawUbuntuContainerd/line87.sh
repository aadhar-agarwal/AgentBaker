[Unit]
Description=a timer that delays containerd-monitor from starting too soon after boot
[Timer]
OnBootSec=30min
[Install]
WantedBy=multi-user.target
#EOF
