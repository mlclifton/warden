# Build, Lint, and Test Commands

This project consists primarily of shell scripts for managing Incus containers and AI coding sandboxes. As a shell-script based utility, there is no traditional build process, but we maintain quality gates for linting and testing.

### Building

No compilation is required since this is a shell-based tool. However, ensure scripts are executable:

```bash
# Make all shell scripts executable
chmod +x *.sh

### Linting

Use shellcheck for static analysis of bash scripts:

```bash
# Lint all shell scripts
shellcheck *.sh

# Lint a specific script
shellcheck warden.sh

# Fix formatting with shfmt
shfmt -w *.sh
```

### Testing

Currently, testing is manual due to the nature of container management. Automated tests may be added in the future.

```bash
# Manual testing workflow
./warden.sh create test-project
./warden.sh info test-project
./warden.sh connect test-project  # Manual verification
./warden.sh destroy test-project

# Validate setup with the provided script
./validate_setup.sh
```

### Running a Single Test

No unit tests exist yet. For manual testing of specific functionality:

```bash
# Test container creation
./warden.sh create test-sandbox

# Test connection (will open SSH session)
./warden.sh connect test-sandbox

# Test info display
./warden.sh info test-sandbox

# Clean up
./warden.sh destroy test-sandbox
```

---

## Code Style Guidelines

This project follows shell scripting best practices for maintainability and reliability.

### General Principles

- **Language**: Use Bash (#!/bin/bash) for all scripts
- **Shebang**: Include `#!/bin/bash` at the top of every script
- **Executable**: Ensure scripts have execute permissions
- **Documentation**: Add comments for complex logic
- **Error Handling**: Always check for errors and exit appropriately

### File Structure

```
the_warden/
├── warden.sh              # Main jail manager script
├── validate_setup.sh  # Validation script
├── AGENTS.md          # This file
├── the_warden_prd.md  # Product requirements
└── .beads/            # Issue tracking
```

### Naming Conventions

- **Scripts**: Use lowercase with hyphens (e.g., `warden.sh`, `validate-setup.sh`)
- **Functions**: Use lowercase with underscores (e.g., `create_container()`)
- **Variables**: Use lowercase with underscores (e.g., `container_name`)
- **Constants**: Use uppercase with underscores (e.g., `DEFAULT_MEMORY="8GB"`)

### Imports and Dependencies

- Source external scripts at the top: `source common.sh`
- Use absolute paths when possible
- Declare dependencies clearly in comments

### Formatting

- **Indentation**: Use 4 spaces (not tabs)
- **Line Length**: Keep lines under 80 characters
- **Quotes**: Use double quotes for variables: `"$variable"`
- **Braces**: Use `${variable}` for clarity
- **Arrays**: Use proper bash arrays: `array=("item1" "item2")`

### Error Handling

```bash
# Always check command success
if ! command; then
    echo "Error: command failed" >&2
    exit 1
fi

# Use set -e for strict error checking
set -euo pipefail

# Custom error function
error() {
    echo "Error: $*" >&2
    exit 1
}
```

### Functions

```bash
# Function definition
create_container() {
    local container_name="$1"
    local project_path="$2"
    
    # Function body
    incus launch images:ubuntu/22.04 "$container_name" || error "Failed to create container"
}

# Call function
create_container "my-project" "/path/to/project"
```

### Variables and Constants

```bash
# Constants
readonly DEFAULT_CPU="4"
readonly DEFAULT_MEMORY="8GB"

# Local variables in functions
local container_name="$1"

# Global variables (minimize use)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

### Logging and Output

```bash
# Info messages
info() {
    echo "INFO: $*" >&2
}

# Warning messages
warn() {
    echo "WARN: $*" >&2
}

# Error messages
error() {
    echo "ERROR: $*" >&2
    exit 1
}

# Usage
info "Creating container $name"
```

### Security Considerations

- DO NOT store secrets in scripts
- Use environment variables for sensitive data
- Validate all user inputs
- Use `incus` with unprivileged containers
- Implement proper ID mapping for file permissions

### Docker/Container Best Practices

- Use specific image tags, not `latest`
- Clean up containers after use
- Handle container networking properly
- Mount volumes with correct permissions
- Enable nesting for Docker-in-Incus

### Testing Guidelines

- Test scripts in isolated environments first
- Verify Incus installation and permissions
- Test network connectivity
- Validate file permissions and mappings
- Document manual test procedures

### Documentation

- Add header comments to all scripts
- Include usage examples
- Document function parameters
- Keep README updated with changes

### Build Log ad Decision Records

- Keep track of implementation decisions in build_log.md

### Example Script Structure

```bash
#!/bin/bash
# warden.sh - Jail Manager for AI coding sandboxes
# Description: Main script for managing Incus containers

set -euo pipefail

# Constants
readonly SCRIPT_VERSION="0.1.0"
readonly DEFAULT_CPU="4"
readonly DEFAULT_MEMORY="8GB"

# Functions
info() { echo "INFO: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
    create <name>    Create a new sandbox
    connect <name>   Connect to sandbox
    destroy <name>   Destroy sandbox
    info <name>      Show sandbox info
    help             Show this help

Examples:
    $0 create my-project
    $0 connect my-project
EOF
}

create_sandbox() {
    local name="$1"
    # Implementation
    info "Creating sandbox: $name"
}

# Main
main() {
    case "${1:-}" in
        create) create_sandbox "$2" ;;
        connect) connect_sandbox "$2" ;;
        destroy) destroy_sandbox "$2" ;;
        info) show_info "$2" ;;
        help|*) usage ;;
    esac
}

main "$@"
```
