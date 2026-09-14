#!/usr/bin/env bash
# Regenerate the Go bindings for proto/helios/v1 into proto/gen/go.
#
# buf is preferred (it bundles the compiler, so there is no protoc version to
# keep in sync across machines); protoc is the fallback for environments that
# already have it. Either way the plugins are pinned, because an unpinned
# protoc-gen-go quietly changes the generated API surface between releases.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}/proto"

PROTOC_GEN_GO_VERSION="v1.36.6"
PROTOC_GEN_GO_GRPC_VERSION="v1.5.1"

export PATH="$(go env GOPATH)/bin:${PATH}"

ensure_plugin() {
  local bin=$1 pkg=$2 version=$3
  command -v "${bin}" >/dev/null 2>&1 && return 0
  echo "installing ${bin}@${version}"
  go install "${pkg}@${version}"
}

ensure_plugin protoc-gen-go      google.golang.org/protobuf/cmd/protoc-gen-go          "${PROTOC_GEN_GO_VERSION}"
ensure_plugin protoc-gen-go-grpc google.golang.org/grpc/cmd/protoc-gen-go-grpc         "${PROTOC_GEN_GO_GRPC_VERSION}"

# Stale files left behind by a renamed message are worse than missing ones:
# they compile and silently shadow the new name.
find gen/go -name '*.pb.go' -delete

if command -v buf >/dev/null 2>&1; then
  buf lint
  buf generate
else
  echo "buf not found; falling back to protoc" >&2
  command -v protoc >/dev/null 2>&1 || {
    echo "neither buf nor protoc is installed — install buf: go install github.com/bufbuild/buf/cmd/buf@v1.47.2" >&2
    exit 1
  }
  protoc -I . \
    --go_out=gen/go --go_opt=paths=source_relative \
    --go-grpc_out=gen/go --go-grpc_opt=paths=source_relative,require_unimplemented_servers=false \
    helios/v1/*.proto
fi

cd gen/go && go mod tidy
echo "✓ proto bindings regenerated"
