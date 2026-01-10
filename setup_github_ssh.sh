#!/usr/bin/env bash
#
# Setup GitHub SSH key for the new machine
# Run this on the NEW machine after installation

set -euo pipefail

echo "========================================="
echo "GitHub SSH Key Setup"
echo "========================================="
echo

# Check if SSH key exists
if [[ -f ~/.ssh/id_rsa.pub ]]; then
    echo "✓ SSH key already exists!"
    echo
elif [[ -f ~/.ssh/id_ed25519.pub ]]; then
    echo "✓ SSH key already exists!"
    echo
else
    echo "No SSH key found. Generating new SSH key..."
    read -rp "Enter your email for SSH key: " email
    ssh-keygen -t ed25519 -C "$email" -f ~/.ssh/id_ed25519 -N ""
    echo "✓ SSH key generated!"
    echo
fi

# Display the public key
echo "========================================="
echo "Your SSH Public Key:"
echo "========================================="
if [[ -f ~/.ssh/id_ed25519.pub ]]; then
    cat ~/.ssh/id_ed25519.pub
elif [[ -f ~/.ssh/id_rsa.pub ]]; then
    cat ~/.ssh/id_rsa.pub
fi
echo "========================================="
echo

echo "Next steps:"
echo "1. Copy the SSH key above (entire line)"
echo "2. Go to: https://github.com/settings/keys"
echo "3. Click 'New SSH key'"
echo "4. Paste the key and give it a title"
echo "5. Come back here and press Enter"
echo

read -rp "Press Enter after adding the key to GitHub..." 

echo
echo "Testing GitHub SSH connection..."
if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    echo "✓ Success! You're authenticated with GitHub"
else
    echo "⚠ Test failed. Make sure you added the key to GitHub."
    echo "  Try manually: ssh -T git@github.com"
fi
