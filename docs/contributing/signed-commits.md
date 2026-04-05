# Signed Commits Guide (For Future Implementation)

> **Status**: Not yet required. This document is for future reference when the project grows and needs stricter security controls.

## What are Signed Commits?

Signed commits are Git commits cryptographically signed using GPG (GNU Privacy Guard) or SSH keys. This proves the commit was actually made by the claimed author, preventing impersonation attacks.

## Why Use Signed Commits?

### Security Benefits

- **Identity Verification**: Confirms the commit author is who they claim to be
- **Impersonation Prevention**: Attackers cannot forge commits in your name
- **Supply Chain Security**: Verifies code hasn't been tampered with in the commit history
- **Audit Trail**: Provides cryptographic proof of code authorship

### When to Enable

Consider requiring signed commits when:

- Project has multiple external contributors
- Project is widely used in production
- Part of a larger organization with security requirements
- Handling sensitive data or security-critical code

## How to Set Up

### For Contributors

#### Option 1: GPG Signing (Traditional)

1. **Generate a GPG key**:
   ```bash
   gpg --full-generate-key
   # Select: RSA and RSA, 4096 bits, no expiration
   ```

2. **List your GPG keys**:
   ```bash
   gpg --list-secret-keys --keyid-format=long
   # Look for: sec   rsa4096/XXXXXXXXXXXXXXXX 2024-01-01 [SC]
   # The X's are your key ID
   ```

3. **Tell Git your GPG key**:
   ```bash
   git config --global user.signingkey XXXXXXXXXXXXXXXX
   git config --global commit.gpgsign true
   git config --global gpg.program gpg
   ```

4. **Export and add to GitHub**:
   ```bash
   gpg --armor --export XXXXXXXXXXXXXXXX
   # Copy output and paste into GitHub Settings > SSH and GPG keys > New GPG key
   ```

5. **Sign commits**:
   ```bash
   git commit -S -m "feat: new feature"
   # Or automatically sign all commits (already set commit.gpgsign true)
   git commit -m "feat: new feature"
   ```

#### Option 2: SSH Signing (Simpler, Recommended)

If you already use SSH keys for GitHub:

1. **Tell Git to use SSH signing**:
   ```bash
   git config --global gpg.format ssh
   git config --global user.signingkey ~/.ssh/id_ed25519.pub
   git config --global commit.gpgsign true
   ```

2. **Add SSH key to GitHub** (if not already):
   ```bash
   cat ~/.ssh/id_ed25519.pub
   # Paste into GitHub Settings > SSH and GPG keys > New SSH key
   # Select "Signing Key" as the key type
   ```

3. **Sign commits automatically**:
   ```bash
   git commit -m "feat: new feature"
   # All commits now signed with your SSH key
   ```

### For Repository Owners

#### Enable Required Signed Commits

1. Go to **Settings > Rules > Rulesets**
2. Create new ruleset for your default branch (e.g., `main`)
3. Add rule: **Require signed commits**
4. Enable the ruleset

Or use branch protection (classic):

1. Go to **Settings > Branches**
2. Edit branch protection for `main`
3. Check **Require signed commits**
4. Save changes

#### Verify Signatures Locally

```bash
# Check signature on a commit
git log --show-signature -1

# Verify all commits in a range
git log --show-signature main~10..main

# Check if a specific commit is signed
git verify-commit HEAD
```

## Visual Indicators

On GitHub, signed commits show a **"Verified"** badge:

- **Green "Verified"**: Valid signature from known key
- **Gray "Partially verified"**: Signed but email doesn't match committer email
- **Unverified**: Signature invalid or key not in GitHub

## Common Issues

### "gpg failed to sign the data"

```bash
# On macOS, may need to configure pinentry
export GPG_TTY=$(tty)
# Add to ~/.zshrc or ~/.bashrc
```

### "Could not find a usable signing program"

```bash
# Ensure GPG is installed
which gpg

# On macOS with Homebrew
brew install gnupg pinentry-mac

# Configure Git to use correct GPG
git config --global gpg.program $(which gpg)
```

### Commits show "Unverified" on GitHub

1. Check your Git email matches GitHub email:
   ```bash
   git config user.email
   # Should match your GitHub primary email
   ```

2. Ensure GPG key is added to GitHub and not expired

3. Check key is not revoked or expired:
   ```bash
   gpg --list-keys
   ```

## Trade-offs

### Benefits

- Strong identity verification
- Prevents certain supply chain attacks
- Required by some security standards

### Costs

- Setup friction for new contributors
- Additional tooling required (GPG or SSH setup)
- May deter casual contributions
- Key management overhead

## Recommendation for This Project

**Current Phase**: Early development, small contributor base

- ✅ CODEOWNERS sufficient for now
- ✅ CI checks enforce quality
- ❌ Signed commits not yet required

**Future Phase**: When ready

1. Add this to CONTRIBUTING.md:
   ```markdown
   ## Signed Commits (Required)
   
   All commits must be signed. See [docs/contributing/signed-commits.md](docs/contributing/signed-commits.md) for setup.
   ```

2. Enable "Require signed commits" in branch protection

3. Add CI check to verify signatures on PRs

## References

- [GitHub Docs: Signing commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)
- [GitHub Docs: SSH commit signing](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification#ssh-commit-signature-verification)
- [Git Docs: Signing your work](https://git-scm.com/book/en/v2/Git-Tools-Signing-Your-Work)
