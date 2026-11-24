#!/usr/bin/env bash
# 07_test_rbac.sh - Test Kubernetes RBAC Permissions
# Run after 06_generate_user_certs.sh
# Validates that all users have correct permissions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/user-certs"

# Color codes for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

# ============================================================================
# Function to test permission
# ============================================================================
test_permission() {
  local user=$1
  local action=$2
  local resource=$3
  local namespace=$4
  local should_pass=$5
  
  local kubeconfig="$CERTS_DIR/kubeconfig-${user}"
  
  if [ ! -f "$kubeconfig" ]; then
    echo -e "${RED}✗${NC} Kubeconfig not found: $kubeconfig"
    ((TESTS_FAILED++))
    return 1
  fi
  
  # Parse the permission action
  local verb=""
  case "$action" in
    "get") verb="get" ;;
    "list") verb="list" ;;
    "watch") verb="watch" ;;
    "create") verb="create" ;;
    "delete") verb="delete" ;;
    "patch") verb="patch" ;;
    *) verb="$action" ;;
  esac
  
  # Run the permission check
  local output
  output=$(KUBECONFIG="$kubeconfig" kubectl auth can-i "$verb" "$resource" -n "$namespace" 2>&1 || true)
  
  local allowed="no"
  if echo "$output" | grep -q "yes"; then
    allowed="yes"
  fi
  
  # Check if result matches expectation
  if [ "$allowed" == "$should_pass" ]; then
    echo -e "${GREEN}✓${NC} $user can-i $verb $resource in $namespace: $allowed (expected: $should_pass)"
    ((TESTS_PASSED++))
    return 0
  else
    echo -e "${RED}✗${NC} $user can-i $verb $resource in $namespace: $allowed (expected: $should_pass)"
    ((TESTS_FAILED++))
    return 1
  fi
}

# ============================================================================
# Main Testing
# ============================================================================
echo "🧪 Testing Kubernetes RBAC Permissions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test Developer Permissions (alice/john in dev namespace)
echo "👨‍💻 Testing Developer Permissions (alice - developers group)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "alice" "get" "pods" "dev" "yes"
test_permission "alice" "list" "pods" "dev" "yes"
test_permission "alice" "create" "pods" "dev" "yes"
test_permission "alice" "delete" "pods" "dev" "yes"
test_permission "alice" "get" "deployments" "dev" "yes"
test_permission "alice" "create" "deployments" "dev" "yes"
test_permission "alice" "get" "ingresses" "dev" "yes"
test_permission "alice" "create" "ingresses" "dev" "yes"
echo ""

# Test Developer Cannot Access Other Namespaces
echo "🚫 Testing Developer Cannot Access Other Namespaces..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "alice" "get" "pods" "auth" "no"
test_permission "alice" "get" "pods" "kube-system" "no"
test_permission "alice" "get" "nodes" "default" "no"
echo ""

# Test Viewer Permissions (bob/mary in dev namespace)
echo "👁️  Testing Viewer Permissions (bob - viewers group)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "bob" "get" "pods" "dev" "yes"
test_permission "bob" "list" "pods" "dev" "yes"
test_permission "bob" "watch" "pods" "dev" "yes"
echo ""

# Test Viewer Cannot Modify
echo "🚫 Testing Viewer Cannot Modify Resources..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "bob" "create" "pods" "dev" "no"
test_permission "bob" "delete" "pods" "dev" "no"
test_permission "bob" "patch" "deployments" "dev" "no"
echo ""

# Test Auth Admin Permissions
echo "🔐 Testing Auth Admin Permissions (carol - auth-admins group)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "carol" "get" "pods" "auth" "yes"
test_permission "carol" "create" "pods" "auth" "yes"
test_permission "carol" "delete" "pods" "auth" "yes"
echo ""

# Test Auth Admin Cannot Access Dev
echo "🚫 Testing Auth Admin Cannot Access Dev Namespace..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "carol" "get" "pods" "dev" "no"
test_permission "carol" "create" "pods" "dev" "no"
echo ""

# Test Cluster Admin Permissions
echo "🌍 Testing Cluster Admin Permissions (sabeen - k8s-admins group)..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
test_permission "sabeen" "get" "pods" "dev" "yes"
test_permission "sabeen" "get" "pods" "auth" "yes"
test_permission "sabeen" "get" "pods" "kube-system" "yes"
test_permission "sabeen" "get" "nodes" "default" "yes"
test_permission "sabeen" "delete" "nodes" "default" "yes"
echo ""

# ============================================================================
# Practical Testing - Actual kubectl operations
# ============================================================================
echo "🔍 Practical Testing - Running Actual kubectl Commands..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

test_actual_command() {
  local user=$1
  local cmd=$2
  local should_succeed=$3
  local kubeconfig="$CERTS_DIR/kubeconfig-${user}"
  
  echo -n "Testing: $user → $cmd ... "
  
  output=$(KUBECONFIG="$kubeconfig" eval "$cmd" 2>&1 || true)
  
  if echo "$output" | grep -q "Forbidden\|Error"; then
    if [ "$should_succeed" == "no" ]; then
      echo -e "${GREEN}✓${NC} (correctly denied)"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} (unexpectedly denied)"
      echo "  Output: $output"
      ((TESTS_FAILED++))
    fi
  else
    if [ "$should_succeed" == "yes" ]; then
      echo -e "${GREEN}✓${NC} (allowed)"
      ((TESTS_PASSED++))
    else
      echo -e "${RED}✗${NC} (unexpectedly allowed)"
      ((TESTS_FAILED++))
    fi
  fi
}

# Test actual commands
test_actual_command "alice" "kubectl get pods -n dev" "yes"
test_actual_command "alice" "kubectl get pods -n auth" "no"
test_actual_command "bob" "kubectl get pods -n dev" "yes"
test_actual_command "bob" "kubectl delete pod nonexistent -n dev" "no"
test_actual_command "carol" "kubectl get pods -n auth" "yes"
test_actual_command "sabeen" "kubectl get nodes" "yes"
echo ""

# ============================================================================
# Summary
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Test Results Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "  ${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}✅ All RBAC tests passed!${NC}"
  exit 0
else
  echo -e "${RED}❌ Some tests failed. Review the output above.${NC}"
  exit 1
fi
