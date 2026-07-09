---
description: Set up two-node-toolbox configuration for deployment
---

You are helping a user set up the two-node-toolbox repository for the first time. Guide them through the configuration process step by step.

## Command Arguments

The user may specify what they want to configure:
- `/setup` or `/setup` with no args: Ask what to configure (default: aws + dev-scripts)
- `/setup external`: Configure external host only
- `/setup aws`: Configure AWS hypervisor only
- `/setup kcli`: Configure kcli installation only
- `/setup dev-scripts`: Configure dev-scripts installation only
- `/setup all`: Configure all four options
Present the options in categories. external and aws are in the "hypervisor" category. kcli and dev-scripts are in the "installer" category.

## Your Task

Based on the argument provided (or user's interactive choice), guide them through configuring the selected deployment method(s). For each selected method:

1. **Check current state** - Verify what's already configured
2. **Explain prerequisites** - Check if required tools/files are present
3. **Guide file setup** - Help copy templates and configure files (ONE STEP AT A TIME)
4. **Provide resource links** - Give URLs for external resources they need
5. **Validate configuration** - Check if files are properly set up
6. **Suggest next steps** - Provide commands to run next

## Shared Prerequisites

### SSH Key Check

All deployment methods require an SSH key on the local machine. Check for any of these files:
- `~/.ssh/id_ed25519.pub` (preferred)
- `~/.ssh/id_rsa.pub`
- Any `~/.ssh/id_*.pub` file

If no SSH key exists, create one with: `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`

**Note for non-default key paths:** Set `SSH_PUBLIC_KEY` in [config/instance.env](config/instance.env). This is used by both the AWS hypervisor and dev-scripts deployments.

### Inventory File

Required for: external, kcli, dev-scripts (not AWS - it auto-generates inventory)

- File: [deploy/openshift-clusters/inventory.ini](deploy/openshift-clusters/inventory.ini)
- Template: [deploy/openshift-clusters/inventory.ini.sample](deploy/openshift-clusters/inventory.ini.sample)
- Check if it exists and has been edited (differs from sample)
- User needs to provide: host IP, SSH user, optional sudo password
- Suggest copying: `cp deploy/openshift-clusters/inventory.ini.sample deploy/openshift-clusters/inventory.ini`

### Ansible Collections

Required for: external, kcli, dev-scripts

- Check if [collections/requirements.yml](collections/requirements.yml) exists
- Suggest: `ansible-galaxy collection install -r collections/requirements.yml`

### Pull Secret

Required for: kcli, dev-scripts

The same pull secret is used by both kcli and dev-scripts. Create it once in the central config folder: [config/pull-secret.json](config/pull-secret.json). The sync (run automatically before deploy and cluster `make` targets, or explicitly via `cd deploy && make sync-config`) distributes it to both role locations automatically.

**Setup logic:**
- Check if [config/pull-secret.json](config/pull-secret.json) exists
- If not, check the canonical locations (`deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json` and `deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json`) - a file there means the user configured it the direct-edit way, which is still valid
- If it doesn't exist anywhere:
  - User gets pull secret from: https://cloud.redhat.com/openshift/install/pull-secret
  - **For CI builds**: Must include `registry.ci.openshift.org` access (see [CI Token](#ci-token) below)
  - Suggest creating [config/pull-secret.json](config/pull-secret.json) and pasting content

**Validation:**
- Validate pull secret is valid JSON: `jq . < config/pull-secret.json`
- Check for CI registry access (if needed): `jq '.auths | has("registry.ci.openshift.org")' < config/pull-secret.json`

### CI Token

Required for: dev-scripts (when using CI builds)

- Visit: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com
- Click name (top right) → "Copy login command" → "Display Token"
- Copy the API token

---

## Configuration Sections

### External Host Configuration

**Purpose**: Set up to deploy on your own RHEL 9 server (not AWS)

**Prerequisites to check:**
- Check if ansible is installed: `which ansible-playbook`
- SSH key exists (see [SSH Key Check](#ssh-key-check))
- Inventory file configured (see [Inventory File](#inventory-file))
- Ansible collections installed (see [Ansible Collections](#ansible-collections))

**Files to configure:**

1. **RHSM credentials** (3 options - user picks one):
   - **Option A (Recommended)**: Environment variables
     - `export RHSM_ACTIVATION_KEY="your-key"`
     - `export RHSM_ORG="your-org-id"`
     - Guide: https://access.redhat.com/solutions/3341191

   - **Option B**: Local config file [config/init-host.yml.local](config/init-host.yml.local)
     - Base file: [deploy/openshift-clusters/vars/init-host.yml](deploy/openshift-clusters/vars/init-host.yml)
     - Check if exists (also accept the direct-edit location `deploy/openshift-clusters/vars/init-host.yml.local`)
     - Suggest copying: `cp deploy/openshift-clusters/vars/init-host.yml config/init-host.yml.local`
     - The sync distributes it to `deploy/openshift-clusters/vars/init-host.yml.local`; suggest `cd deploy && make sync-config` before running the playbook directly

   - **Option C**: Command line (they'll add when running playbook)

**Validation:**
- Verify inventory file exists
- Check if RHSM credentials are configured (env vars or file)

**Next steps:**
- Run: `ansible-playbook deploy/openshift-clusters/init-host.yml -i deploy/openshift-clusters/inventory.ini`

---

### AWS Hypervisor Configuration

**Purpose**: Automate RHEL hypervisor deployment in AWS EC2

**Prerequisites to check:**
- AWS CLI configured: `aws configure list` should show profile and credentials
- Check if `AWS_PROFILE` environment variable is set
- Required tools: make, aws, jq, rsync, golang, ansible
- Check if `~/.ssh/config` file exists

**Files to configure:**

1. **Instance environment**: [config/instance.env](config/instance.env)
   - Template: [config/instance.env.template](config/instance.env.template)
   - Check if it exists (also accept the direct-edit location [deploy/aws-hypervisor/instance.env](deploy/aws-hypervisor/instance.env))
   - User must edit ALL variables with their specific values
   - Optional: Set `RHSM_ACTIVATION_KEY` and `RHSM_ORG` for hands-off deployment
     - Guide: https://access.redhat.com/solutions/3341191
   - Suggest copying: `cp config/instance.env.template config/instance.env`
   - Deploy and cluster `make` targets sync it to `deploy/aws-hypervisor/instance.env` where the scripts read it

**Validation:**
- Verify [config/instance.env](config/instance.env) (or `deploy/aws-hypervisor/instance.env`) exists
- Test by sourcing: `source config/instance.env` (should not error)

**Next steps:**
- Quick deploy: `cd deploy && make deploy arbiter-ipi`
- Or see all options: `cd deploy && make help`

---

### kcli Installation Configuration

**Purpose**: Deploy OpenShift using kcli virtualization tool (fencing topology)

**Prerequisites to check:**
- SSH key exists (see [SSH Key Check](#ssh-key-check))
- Inventory file configured (see [Inventory File](#inventory-file))
- Ansible collections installed (see [Ansible Collections](#ansible-collections))
- Pull secret configured (see [Pull Secret](#pull-secret))

**Files to configure:**

1. **Optional persistent config**: [config/kcli.yml](config/kcli.yml)
   - Template: [config/kcli.yml.template](config/kcli.yml.template)
   - Check if exists (also accept the direct-edit location [deploy/openshift-clusters/vars/kcli.yml](deploy/openshift-clusters/vars/kcli.yml))
   - For setting preferred defaults (cluster name, resources, etc.)
   - Suggest copying: `cp config/kcli.yml.template config/kcli.yml`
   - The sync distributes it to `deploy/openshift-clusters/vars/kcli.yml`; suggest `cd deploy && make sync-config` before running the playbook directly

**Validation:**
- Verify inventory file exists
- Verify pull secret exists and is valid JSON

**Next steps:**
- Run: `ansible-playbook deploy/openshift-clusters/kcli-install.yml -i deploy/openshift-clusters/inventory.ini`

---

### Dev-scripts Installation Configuration

**Purpose**: Deploy OpenShift using traditional dev-scripts method (arbiter or fencing)

**Prerequisites to check:**
- SSH key exists (see [SSH Key Check](#ssh-key-check))
- Inventory file configured (see [Inventory File](#inventory-file))
- Ansible collections installed (see [Ansible Collections](#ansible-collections))
- Pull secret configured (see [Pull Secret](#pull-secret))

**Files to configure:**

1. **Topology config files** in [config/](config/):

   a. **Arbiter config**: [config/config_arbiter.sh](config/config_arbiter.sh)
      - Template: [config/config_arbiter_example.sh](config/config_arbiter_example.sh)
      - Check if exists (also accept the direct-edit location `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh`)
      - User must set:
        - `OPENSHIFT_RELEASE_IMAGE` (e.g., `quay.io/openshift-release-dev/ocp-release:4.19.0-rc.5-multi-x86_64`)
        - `CI_TOKEN` (see [CI Token](#ci-token)) unless using `OPENSHIFT_CI="True"`
      - Suggest copying: `cp config/config_arbiter_example.sh config/config_arbiter.sh`

   b. **Fencing config**: [config/config_fencing.sh](config/config_fencing.sh)
      - Template: [config/config_fencing_example.sh](config/config_fencing_example.sh)
      - Check if exists (also accept the direct-edit location `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh`)
      - Same requirements as arbiter config
      - Suggest copying: `cp config/config_fencing_example.sh config/config_fencing.sh`

   - The sync distributes these to `deploy/openshift-clusters/roles/dev-scripts/install-dev/files/`; suggest `cd deploy && make sync-config` before running the playbook directly
   - **Config reference**: https://github.com/openshift-metal3/dev-scripts/blob/master/config_example.sh

**Validation:**
- Verify inventory file exists
- For arbiter: Check [config/config_arbiter.sh](config/config_arbiter.sh) (or the direct-edit location) exists
- For fencing: Check [config/config_fencing.sh](config/config_fencing.sh) (or the direct-edit location) exists
- Verify pull secret exists and is valid JSON

**Next steps:**
- Interactive: `ansible-playbook deploy/openshift-clusters/setup.yml -i deploy/openshift-clusters/inventory.ini`
- Non-interactive arbiter: `ansible-playbook deploy/openshift-clusters/setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i deploy/openshift-clusters/inventory.ini`
- Non-interactive fencing: `ansible-playbook deploy/openshift-clusters/setup.yml -e "topology=fencing" -e "interactive_mode=false" -i deploy/openshift-clusters/inventory.ini`

---

## General Workflow

1. **Parse the command argument** to determine what to configure
2. **If no argument or unclear**, ask the user interactively what they want to set up
   - Present options: external, aws, kcli, dev-scripts, all
   - Default suggestion: aws + dev-scripts
3. **For each selected configuration method**:
   - Announce what you're configuring
   - Check prerequisites and current state
   - **Process ONE step at a time** following this pattern:
     a. Identify the next action needed (copy file, edit file, install package, etc.)
     b. Provide clear instructions for that ONE action
     c. **STOP and wait for user confirmation that the step is complete**
     d. When user resumes, **verify the step was completed** before proceeding
     e. Only after verification, move to the next step
4. **After all steps for a method are complete**:
   - Perform final validation
   - Suggest next steps
   - If configuring multiple methods, move to the next method

## Interactive Step-by-Step Pattern

**CRITICAL**: You must follow this pattern for EVERY action:

### For Actions Claude Can Execute (file operations, checks, etc.):

1. **Announce and execute**: "Let me [action]..." then use the appropriate tool
   - File copying: Use Bash tool to copy files
   - File reading: Use Read tool to check files
   - Validation: Use Bash/Read tools to verify
2. **If user rejects the tool**: Fall back to manual instructions
   - Provide the command for the user to run
   - Ask them to let you know when done
3. **After execution (or user completion)**:
   - Verify the result
   - Move to next step or stop if user input is needed

### For Actions Requiring User Input (editing files, obtaining credentials, etc.):

1. **Present the action**: "Next, you need to [action]. Here's how..."
2. **Give specific instructions**: What to edit, where to get credentials, etc.
3. **STOP**: End your response and wait for the user
4. **On resume**:
   - First, check if the step was completed (read files, run validation commands)
   - If complete: Acknowledge and move to next step
   - If incomplete: Ask what went wrong and help troubleshoot
   - Never assume a step is complete without verification

**Example flow (Claude executes):**

```
Assistant: "Let me copy the inventory template for you."
[Uses Bash tool: cp deploy/openshift-clusters/inventory.ini.sample deploy/openshift-clusters/inventory.ini]

"Great! I've created the inventory file. Now you need to edit it with your host information. Please update:
- The host IP address
- The SSH user
- (Optional) sudo password

Let me know when you've edited the file."

[STOP - Wait for user]

User: "Done"

Assistant: [Checks if file exists]

"Great\! I can see the inventory file has been created. Now let's edit it with your host information..."

[Proceed to next step]
```

## What Claude Should Execute vs. What Requires User Action

### Claude Should Execute (Proactively):
- Copying template files (cp commands)
- Reading files to check if they exist
- Validating file contents (jq, grep, etc.)
- Checking prerequisites (which, ls, etc.)
- Any read-only or safe file operations

### User Must Do (Claude provides instructions):
- Editing files with user-specific values (IP addresses, credentials, etc.)
- Obtaining external resources (pull secrets, CI tokens, activation keys)
- Installing packages (ansible-galaxy, dnf, etc.) - unless user explicitly asks
- Setting environment variables in their shell
- Running deployment playbooks (final steps)

### Fallback Pattern:
If user rejects a tool use that Claude tried to execute:
1. Provide the manual command
2. Ask user to run it and confirm when done
3. Continue with verification step when they resume

## Important Notes

- Always check if files already exist before suggesting to create them
- Use file path links in markdown format: `[filename](path/to/file)` for VSCode clickability
- Distinguish between files that can be copied as-is vs. files that need editing
- Be clear about which values are required vs. optional
- After each user action, VERIFY it was completed before proceeding
- If prerequisites are missing, clearly state what needs to be installed
- Shared prerequisites are documented in [Shared Prerequisites](#shared-prerequisites) - check these first when configuring multiple methods
- The main README states defaults: "By default, we'll configure the AWS hypervisor and the dev-scripts installation"
- **NEVER skip verification steps** - always confirm each action was completed successfully
- **STOP after giving each instruction** - wait for user to complete it and confirm
