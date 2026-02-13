#!/usr/bin/env sh
set -eu

# Downloads a tarball from GitHub Actions unsigned-release workflow
# and unpacks it into ~/.local/.

main() {
    platform="$(uname -s)"
    arch="$(uname -m)"
    channel="${ZED_CHANNEL:-stable}"
    
    # Use TMPDIR if available
    if [ -n "${TMPDIR:-}" ] && [ -d "${TMPDIR}" ]; then
        temp="$(mktemp -d "$TMPDIR/zed-XXXXXX")"
    else
        temp="$(mktemp -d "/tmp/zed-XXXXXX")"
    fi

    if [ "$platform" = "Darwin" ]; then
        echo "This script is for Linux only. Use https://zed.dev/install.sh for macOS."
        exit 1
    elif [ "$platform" != "Linux" ]; then
        echo "Unsupported platform $platform"
        exit 1
    fi

    case "$platform-$arch" in
        linux-arm64* | linux-armhf | linux-aarch64)
            arch="aarch64"
            ;;
        linux-x86* | linux-i686*)
            arch="x86_64"
            ;;
        *)
            echo "Unsupported architecture: $arch"
            exit 1
            ;;
    esac

    if command -v curl >/dev/null 2>&1; then
        curl () {
            command curl -fL "$@"
        }
    elif command -v wget >/dev/null 2>&1; then
        curl () {
            wget -O- "$@"
        }
    else
        echo "Could not find 'curl' or 'wget' in your path"
        exit 1
    fi

    linux "$@"

    if [ "$(command -v zed)" = "$HOME/.local/bin/zed" ]; then
        echo "Zed has been installed. Run with 'zed'"
    else
        echo "To run Zed from your terminal, you must add ~/.local/bin to your PATH"
        echo "Run:"

        case "$SHELL" in
            *zsh)
                echo "   echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.zshrc"
                echo "   source ~/.zshrc"
                ;;
            *fish)
                echo "   fish_add_path -U $HOME/.local/bin"
                ;;
            *)
                echo "   echo 'export PATH=\$HOME/.local/bin:\$PATH' >> ~/.bashrc"
                echo "   source ~/.bashrc"
                ;;
        esac

        echo "To run Zed now, '~/.local/bin/zed'"
    fi
}

linux() {
    repo="${GITHUB_REPO:-zed-industries/zed}"
    workflow="unsigned-release.yml"
    branch="${GITHUB_BRANCH:-custom-zed}"
    
    if [ -n "${ZED_BUNDLE_PATH:-}" ]; then
        echo "Using local bundle: $ZED_BUNDLE_PATH"
        cp "$ZED_BUNDLE_PATH" "$temp/zed-linux-$arch.tar.gz"
    else
        echo "Finding latest unsigned-release workflow run for $repo:$branch..."
        
        # Get the latest workflow run ID
        api_url="https://api.github.com/repos/$repo/actions/workflows/$workflow/runs?branch=$branch&status=success&per_page=1"
        
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            response=$(curl -H "Authorization: token $GITHUB_TOKEN" "$api_url")
        else
            response=$(curl "$api_url")
        fi
        
        run_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -n1 | cut -d':' -f2)
        
        if [ -z "$run_id" ]; then
            echo "Error: Could not find successful workflow run"
            echo "Make sure unsigned-release.yml exists and has run successfully on branch: $branch"
            exit 1
        fi
        
        echo "Found workflow run: $run_id"
        
        # Get the artifact download URL
        artifact_api_url="https://api.github.com/repos/$repo/actions/runs/$run_id/artifacts"
        
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            artifacts=$(curl -H "Authorization: token $GITHUB_TOKEN" "$artifact_api_url")
        else
            artifacts=$(curl "$artifact_api_url")
        fi
        
        artifact_name="zed-linux-$arch.tar.gz"
        archive_url=$(echo "$artifacts" | grep -o '"archive_download_url":"[^"]*' | sed "s/\"archive_download_url\":\"//" | head -n1)
        
        if [ -z "$archive_url" ]; then
            echo "Error: Could not find artifact: $artifact_name"
            exit 1
        fi
        
        # Download artifact (it's a zip containing the tarball)
        echo "Downloading artifact..."
        artifact_zip="$temp/artifact.zip"
        
        if [ -n "${GITHUB_TOKEN:-}" ]; then
            curl -H "Authorization: token $GITHUB_TOKEN" -o "$artifact_zip" "$archive_url"
        else
            curl -o "$artifact_zip" "$archive_url"
        fi
        
        # Unzip the artifact
        echo "Extracting..."
        tarball_path="$temp/zed-linux-$arch.tar.gz"
        unzip -j "$artifact_zip" -d "$temp" "$artifact_name"
        
        # Verify the tarball exists
        if [ ! -f "$tarball_path" ]; then
            echo "Error: Expected artifact $artifact_name not found in zip"
            exit 1
        fi
        
        mv "$tarball_path" "$temp/zed-linux-$arch.tar.gz"
    fi

    suffix=""
    if [ "$channel" != "stable" ]; then
        suffix="-$channel"
    fi

    appid=""
    case "$channel" in
      stable)
        appid="dev.zed.Zed"
        ;;
      nightly)
        appid="dev.zed.Zed-Nightly"
        ;;
      preview)
        appid="dev.zed.Zed-Preview"
        ;;
      dev)
        appid="dev.zed.Zed-Dev"
        ;;
      *)
        echo "Unknown release channel: ${channel}. Using stable app ID."
        appid="dev.zed.Zed"
        ;;
    esac

    # Unpack
    rm -rf "$HOME/.local/zed$suffix.app"
    mkdir -p "$HOME/.local/zed$suffix.app"
    tar -xzf "$temp/zed-linux-$arch.tar.gz" -C "$HOME/.local/"

    # Setup ~/.local directories
    mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications"

    # Link the binary
    if [ -f "$HOME/.local/zed$suffix.app/bin/zed" ]; then
        ln -sf "$HOME/.local/zed$suffix.app/bin/zed" "$HOME/.local/bin/zed"
    else
        # support for versions before 0.139.x.
        ln -sf "$HOME/.local/zed$suffix.app/bin/cli" "$HOME/.local/bin/zed"
    fi

    # Copy .desktop file
    desktop_file_path="$HOME/.local/share/applications/${appid}.desktop"
    src_dir="$HOME/.local/zed$suffix.app/share/applications"
    if [ -f "$src_dir/${appid}.desktop" ]; then
        cp "$src_dir/${appid}.desktop" "${desktop_file_path}"
    else
        # Fallback for older tarballs
        cp "$src_dir/zed$suffix.desktop" "${desktop_file_path}"
    fi
    sed -i "s|Icon=zed|Icon=$HOME/.local/zed$suffix.app/share/icons/hicolor/512x512/apps/zed.png|g" "${desktop_file_path}"
    sed -i "s|Exec=zed|Exec=$HOME/.local/zed$suffix.app/bin/zed|g" "${desktop_file_path}"
    
    # Cleanup
    rm -rf "$temp"
}

main "$@"
