#!/usr/bin/env bash

agent_signal_swift() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift "$@"
  elif [[ -n "${XCODE_DEVELOPER_DIR:-}" && -d "$XCODE_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" swift "$@"
  else
    swift "$@"
  fi
}

agent_signal_normalize_archs() {
  local raw="${1:-}"
  raw="${raw//,/ }"

  local arch
  local expanded_arch
  local normalized=""
  for arch in $raw; do
    case "$arch" in
      universal)
        for expanded_arch in arm64 x86_64; do
          if [[ " $normalized " != *" $expanded_arch "* ]]; then
            normalized="${normalized:+$normalized }$expanded_arch"
          fi
        done
        ;;
      native|host|current)
        ;;
      arm64|x86_64)
        if [[ " $normalized " != *" $arch "* ]]; then
          normalized="${normalized:+$normalized }$arch"
        fi
        ;;
      *)
        echo "unsupported architecture '$arch'; use arm64, x86_64, universal, or native" >&2
        return 2
        ;;
    esac
  done

  printf "%s" "$normalized"
}

agent_signal_first_arch() {
  local archs
  archs="$(agent_signal_normalize_archs "${1:-}")" || return
  for arch in $archs; do
    printf "%s" "$arch"
    return 0
  done
}

agent_signal_build_configuration_args() {
  local configuration="$1"
  if [[ "$configuration" == "release" ]]; then
    printf "%s\n" "-c"
    printf "%s\n" "release"
  fi
}

agent_signal_product_bin_path() {
  local product="$1"
  local configuration="$2"
  local arch="${3:-}"
  local args=()

  while IFS= read -r arg; do
    [[ -n "$arg" ]] && args+=("$arg")
  done < <(agent_signal_build_configuration_args "$configuration")
  if [[ -n "$arch" ]]; then
    args+=(--triple "${arch}-apple-macosx")
  fi
  args+=(--product "$product" --show-bin-path)

  if [[ "${#args[@]}" -gt 0 ]]; then
    agent_signal_swift build "${args[@]}"
  else
    agent_signal_swift build
  fi
}

agent_signal_build_product() {
  local product="$1"
  local binary_name="$2"
  local configuration="$3"
  local output_path="$4"
  local raw_archs="${5:-}"
  local archs
  local args=()
  local inputs=()

  archs="$(agent_signal_normalize_archs "$raw_archs")" || return
  mkdir -p "$(dirname "$output_path")"

  while IFS= read -r arg; do
    [[ -n "$arg" ]] && args+=("$arg")
  done < <(agent_signal_build_configuration_args "$configuration")

  if [[ -z "$archs" ]]; then
    if [[ "${#args[@]}" -gt 0 ]]; then
      agent_signal_swift build "${args[@]}" --product "$product" >&2
    else
      agent_signal_swift build --product "$product" >&2
    fi
    local bin_dir
    bin_dir="$(agent_signal_product_bin_path "$product" "$configuration")"
    local bin_path="$bin_dir/$binary_name"
    if [[ ! -x "$bin_path" ]]; then
      echo "built binary not found: $bin_path" >&2
      return 1
    fi
    cp "$bin_path" "$output_path"
    chmod +x "$output_path"
    return 0
  fi

  local arch
  for arch in $archs; do
    if [[ "${#args[@]}" -gt 0 ]]; then
      agent_signal_swift build "${args[@]}" --triple "${arch}-apple-macosx" --product "$product" >&2
    else
      agent_signal_swift build --triple "${arch}-apple-macosx" --product "$product" >&2
    fi
    local bin_dir
    bin_dir="$(agent_signal_product_bin_path "$product" "$configuration" "$arch")"
    local bin_path="$bin_dir/$binary_name"
    if [[ ! -x "$bin_path" ]]; then
      echo "built $arch binary not found: $bin_path" >&2
      return 1
    fi
    inputs+=("$bin_path")
  done

  if [[ "${#inputs[@]}" -eq 1 ]]; then
    cp "${inputs[0]}" "$output_path"
  else
    lipo -create "${inputs[@]}" -output "$output_path"
  fi
  chmod +x "$output_path"
}

agent_signal_verify_binary_archs() {
  local binary_path="$1"
  local raw_archs="$2"
  local label="${3:-$binary_path}"
  local archs
  archs="$(agent_signal_normalize_archs "$raw_archs")" || return
  [[ -z "$archs" ]] && return 0

  if [[ ! -x "$binary_path" ]]; then
    echo "$label is missing or not executable: $binary_path" >&2
    return 1
  fi

  local info
  info="$(lipo -info "$binary_path")"
  local arch
  for arch in $archs; do
    if [[ "$info" != *"$arch"* ]]; then
      echo "$label is missing $arch slice: $info" >&2
      return 1
    fi
  done
}
