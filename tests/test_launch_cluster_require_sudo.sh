#!/bin/bash
#
# Focused behavior tests for launch-cluster.sh --require-sudo.
# All Docker, SSH, and sudo operations are handled by fake commands that log
# their invocations, so no root access or Docker daemon is required.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TMP_BASE="$(mktemp -d)"
TEST_INDEX=0
TESTS_PASSED=0

cleanup() {
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

pass() {
    echo "[PASS] $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "[FAIL] $1" >&2
    if [[ -f "${OUTPUT_LOG:-}" ]]; then
        echo "--- output ---" >&2
        sed -n '1,220p' "$OUTPUT_LOG" >&2
    fi
    if [[ -f "${TEST_LOG:-}" ]]; then
        echo "--- command log ---" >&2
        sed -n '1,220p' "$TEST_LOG" >&2
    fi
    exit 1
}

setup_fixture() {
    TEST_INDEX=$((TEST_INDEX + 1))
    CASE_DIR="$TMP_BASE/case-$TEST_INDEX"
    FIXTURE_DIR="$CASE_DIR/project"
    FAKE_BIN_DIR="$CASE_DIR/bin"
    TEST_LOG="$CASE_DIR/commands.log"
    OUTPUT_LOG="$CASE_DIR/output.log"

    mkdir -p "$FIXTURE_DIR" "$FAKE_BIN_DIR"
    cp "$PROJECT_DIR/launch-cluster.sh" "$FIXTURE_DIR/"
    cp "$PROJECT_DIR/autodiscover.sh" "$FIXTURE_DIR/"
    touch "$FIXTURE_DIR/test.env"
    : > "$TEST_LOG"
    : > "$OUTPUT_LOG"

    # The launch script executed inside the (fake) container.
    printf '#!/bin/bash\nexit 0\n' > "$FIXTURE_DIR/launch-script.sh"

    cat > "$FAKE_BIN_DIR/sudo" <<'SUDO'
#!/bin/bash
echo "sudo $*" >> "$TEST_LOG"
exec "$@"
SUDO

    cat > "$FAKE_BIN_DIR/docker" <<'DOCKER'
#!/bin/bash
echo "docker $*" >> "$TEST_LOG"

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" && "${3:-}" == "--format" ]]; then
    echo "sha256:head"
    exit 0
fi

exit 0
DOCKER

    cat > "$FAKE_BIN_DIR/ssh" <<'SSH'
#!/bin/bash
echo "ssh $*" >> "$TEST_LOG"

if [[ "$*" == *"docker ps --format"* ]]; then
    # No containers are running on remote nodes.
    exit 1
fi

if [[ "$*" == *"docker image inspect"* ]]; then
    if [[ "$*" == *"--format"* ]]; then
        echo "sha256:head"
    fi
    exit 0
fi

exit 0
SSH

    cat > "$FAKE_BIN_DIR/scp" <<'SCP'
#!/bin/bash
echo "scp $*" >> "$TEST_LOG"
exit 0
SCP

    cat > "$FAKE_BIN_DIR/sleep" <<'SLEEP'
#!/bin/bash
exit 0
SLEEP

    chmod +x "$FAKE_BIN_DIR/sudo" "$FAKE_BIN_DIR/docker" "$FAKE_BIN_DIR/ssh" \
        "$FAKE_BIN_DIR/scp" "$FAKE_BIN_DIR/sleep"
}

run_launch() {
    (
        cd "$FIXTURE_DIR"
        PATH="$FAKE_BIN_DIR:$PATH" \
            TEST_LOG="$TEST_LOG" \
            LOCAL_IP="10.0.0.1" \
            ./launch-cluster.sh \
                --config "$FIXTURE_DIR/test.env" \
                -t vllm-node \
                --launch-script "$FIXTURE_DIR/launch-script.sh" \
                -d "$@"
    ) > "$OUTPUT_LOG" 2>&1
}

assert_log_contains() {
    local pattern="$1"
    grep -Eq "$pattern" "$TEST_LOG" || fail "Expected command log to match: $pattern"
}

assert_log_not_contains() {
    local pattern="$1"
    if grep -Eq "$pattern" "$TEST_LOG"; then
        fail "Expected command log not to match: $pattern"
    fi
}

test_solo_launch_prefixes_docker_with_sudo() {
    setup_fixture
    run_launch --solo --require-sudo || fail "solo launch with --require-sudo failed"
    assert_log_contains '^sudo docker run '
    assert_log_contains '^sudo docker cp '
    assert_log_contains '^sudo docker exec '
    pass "solo launch runs every local docker command through sudo"
}

test_cluster_launch_prefixes_remote_docker_with_sudo() {
    setup_fixture
    run_launch --require-sudo --nodes "10.0.0.1,10.0.0.2" --eth-if eth0 --ib-if ib0 \
        || fail "cluster launch with --require-sudo failed"
    assert_log_contains '^sudo docker run '
    assert_log_contains '^sudo docker image inspect '
    # Remote commands must carry the sudo prefix inside the ssh command string.
    assert_log_contains '^ssh .*sudo docker image inspect'
    assert_log_contains '^ssh .*sudo docker run '
    pass "cluster launch sends sudo-prefixed docker commands to workers"
}

test_default_launch_does_not_use_sudo() {
    setup_fixture
    run_launch --solo || fail "default solo launch failed"
    assert_log_contains '^docker run '
    assert_log_not_contains 'sudo docker'
    assert_log_not_contains '^sudo '
    pass "launches without --require-sudo never invoke sudo"
}

test_solo_launch_prefixes_docker_with_sudo
test_cluster_launch_prefixes_remote_docker_with_sudo
test_default_launch_does_not_use_sudo

echo
echo "$TESTS_PASSED test(s) passed."
