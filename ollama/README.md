# Ollama on Aurora

This directory contains resources and configurations for running Ollama with large language models on Aurora.

## Contents

- **gpt-oss-120b-intel-max-gpu/** - Submodule containing scripts, patches, and configuration for running the GPT-OSS-120B model using Ollama on Intel Max GPU

## Managing the Submodule

### Initial Clone

When cloning the Aurora-Inferencing repository for the first time, use the `--recurse-submodules` flag to automatically initialize and update all submodules:

```bash
git clone --recurse-submodules https://github.com/brettin/Aurora-Inferencing
```

### Already Cloned Without Submodules

If you've already cloned the repository without the submodules, initialize and update them:

```bash
# Initialize the submodule configuration
git submodule init

# Fetch and checkout the submodule content
git submodule update
```

Or do both in one step:

```bash
git submodule update --init
```

### Updating the Submodule

To update the submodule to the latest commit from its remote repository:

```bash
# Navigate to the submodule directory
cd ollama/gpt-oss-120b-intel-max-gpu

# Pull the latest changes
git pull origin main

# Return to the parent repository
cd ../..

# Commit the updated submodule reference
git add ollama/gpt-oss-120b-intel-max-gpu
git commit -m "Update gpt-oss-120b-intel-max-gpu submodule"
git push
```

### Working Inside the Submodule

The submodule is a full git repository. You can make changes inside it:

```bash
# Navigate to the submodule
cd ollama/gpt-oss-120b-intel-max-gpu

# Make your changes, then commit
git add <files>
git commit -m "Your commit message"
git push origin main

# Return to parent and update the submodule reference
cd ../..
git add ollama/gpt-oss-120b-intel-max-gpu
git commit -m "Update submodule reference"
git push
```

### Checking Submodule Status

To see the current status of all submodules:

```bash
git submodule status
```

This will show:
- A `-` prefix if the submodule is not initialized
- A `+` prefix if the submodule checkout is different from what the parent repository expects
- A `U` prefix if there are merge conflicts

### Common Issues

**"modified content" or "untracked content" warning:**

This usually means there are uncommitted changes or untracked files in the submodule. Navigate to the submodule and use `git status` to investigate:

```bash
cd ollama/gpt-oss-120b-intel-max-gpu
git status
```

**Submodule is detached HEAD:**

By default, submodules are in detached HEAD state. To work on a branch:

```bash
cd ollama/gpt-oss-120b-intel-max-gpu
git checkout main
```

## More Information

For more information about the GPT-OSS-120B model implementation, see the README in the submodule:
- [gpt-oss-120b-intel-max-gpu/README.md](gpt-oss-120b-intel-max-gpu/README.md)

