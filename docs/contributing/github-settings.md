# GitHub Repository Settings Guide

> **Action Required**: These settings must be configured manually in GitHub UI. They cannot be set via code/files.

## Required Settings (Do This Before First PR)

### 1. Require Status Checks

Prevents merging when CI fails.

**Steps:**
1. Go to **Settings > Rules > Rulesets**
2. Click **"New ruleset"** > **"Import a ruleset"** (or create new)
3. Name: `main-branch-protection`
4. Enforcement: **Active**
5. Targets: Add target **Include default branch** (main)
6. Add rules:
   - ✅ **Restrict deletions**
   - ✅ **Require status checks to pass**
     - Search and add: `lint`, `type-check`, `test (3.10)`, `test (3.11)`, `test (3.12)`
   - ✅ **Require a pull request before merging**
     - ✅ **Require approvals**: 1 (or more if needed)
     - ✅ **Dismiss stale PR approvals when new commits are pushed** ← KEY SETTING
     - ✅ **Require review from Code Owners** (optional but recommended)

7. Click **Create**

Or use classic branch protection:
- Settings > Branches > Add rule for `main`
- Check same options above

### 2. Dismiss Stale Reviews

Forces re-review when code changes.

**Already included in step 1 above:**
- The checkbox **"Dismiss stale PR approvals when new commits are pushed"** handles this

**Why important:**
- Contributor gets approval
- Pushes more code (potentially malicious)
- Without this: can merge immediately
- With this: needs new approval

### 3. Force Push Protection (Owner Exception)

**For Contributors:**
- Go to **Settings > Rules > Rulesets** (or classic branch protection)
- ✅ **Block force pushes** (always enabled by default)

**For Owners (You - @maemreyo):**
You need force push for emergency fixes, so:

1. Go to **Settings > Repository**
2. Under **"Danger Zone"** > **"Allow force pushes"**
   - ⚠️ DO NOT ENABLE THIS globally
3. Instead, use **bypass** option:
   - In Rulesets (step 1 above), scroll to **"Bypass list"**
   - Add: **@maemreyo** as bypass actor
   - Check: **Allow bypass** for force pushes, direct pushes, etc.

Now:
- Contributors: cannot force push (blocked)
- You (@maemreyo): can bypass via command line when needed

## Additional Security Settings

### Require Signed Commits (Future)

When ready to enforce signed commits:
1. Rulesets > Add rule: **Require signed commits**
2. Or classic: Branch protection > Check "Require signed commits"

### Code Review Requirements

**Recommended for production:**
- Require 1+ approving reviews
- Require review from code owners (CODEOWNERS file)
- Require conversation resolution before merging
- Require linear history (no merge commits)

## Settings Summary Checklist

Copy this to an issue and check off as you configure:

```markdown
- [ ] Ruleset created for `main` branch
- [ ] Status checks required: lint, type-check, test (3.10/3.11/3.12)
- [ ] Dismiss stale reviews enabled
- [ ] Force pushes blocked (default)
- [ ] @maemreyo added to bypass list (for emergencies)
- [ ] Require PR before merging
- [ ] Require 1 approval
- [ ] (Optional) Require code owner review
```

## Verification Test

After setup, verify protection works:

1. **Create test PR** with failing CI
   - Should see: ❌ "Required status checks failing"
   - Merge button should be DISABLED

2. **Approve PR**, then push new commit
   - Should see: "Review dismissed because new commits were pushed"
   - Needs re-approval

3. **Try force push** as contributor
   ```bash
   git push --force origin main  # Should fail with "protected branch"
   ```

4. **Try force push as you** (emergency only):
   ```bash
   git push --force-with-lease origin main  # Should work (bypass)
   ```

## Quick Reference: GitHub URLs

- Settings: `https://github.com/maemreyo/omnivoice-server/settings`
- Rulesets: `https://github.com/maemreyo/omnivoice-server/settings/rules`
- Branches: `https://github.com/maemreyo/omnivoice-server/settings/branches`

## Emergency Override

If rules block urgent fix:

1. As repo admin, go to **Settings > Rules**
2. Temporarily **disable** the ruleset
3. Push your fix
4. Re-enable ruleset immediately after

Or use bypass if configured:
```bash
git push origin main --force-with-lease
# With bypass permissions, this works even with protection
```
