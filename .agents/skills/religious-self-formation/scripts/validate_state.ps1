[CmdletBinding()]
param(
    [string]$Root
)

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Join-Path $PSScriptRoot '..\..\..\..'
}

try {
    $Root = (Resolve-Path -LiteralPath $Root -ErrorAction Stop).Path
}
catch {
    [ordered]@{
        status = 'failed'
        validated_root = $Root
        errors = @("Cannot resolve repository root: $($_.Exception.Message)")
        warnings = @()
    } | ConvertTo-Json -Depth 4
    exit 1
}

$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$required = @(
    'AGENTS.md',
    'PURSUIT.md',
    '.agents\skills\religious-self-formation\SKILL.md',
    '.agents\skills\religious-self-formation\agents\openai.yaml',
    'state\continuity.json',
    'state\current-self.md',
    'state\belief-ledger.md',
    'evals\rubric.md',
    'evals\baseline.md',
    'sources\register.md',
    'logs\reasoning-audit.md'
)

foreach ($relativePath in $required) {
    $fullPath = Join-Path $Root $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $errors.Add("Missing required file: $relativePath")
    }
}

$continuity = $null
$continuityPath = Join-Path $Root 'state\continuity.json'
if (Test-Path -LiteralPath $continuityPath -PathType Leaf) {
    try {
        $continuity = Get-Content -LiteralPath $continuityPath -Raw | ConvertFrom-Json
    }
    catch {
        $errors.Add("Invalid continuity JSON: $($_.Exception.Message)")
    }
}

if ($null -ne $continuity) {
    $recordedRoot = [string]$continuity.canonical_root
    if ([string]::IsNullOrWhiteSpace($recordedRoot)) {
        $errors.Add('Continuity does not record a canonical root.')
    }
    elseif ([System.IO.Path]::IsPathRooted($recordedRoot)) {
        try {
            $normalizedRecordedRoot = [System.IO.Path]::GetFullPath($recordedRoot).TrimEnd('\', '/')
            $normalizedValidatedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
            if (-not $normalizedRecordedRoot.Equals($normalizedValidatedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $warnings.Add("Continuity records checkout path '$recordedRoot'; validating active repository '$Root'.")
            }
        }
        catch {
            $errors.Add("Continuity canonical root is invalid: $recordedRoot")
        }
    }
    elseif ($recordedRoot -ne '.') {
        $errors.Add("Continuity canonical root must be absolute or '.': $recordedRoot")
    }

    if ($continuity.objective.primary -ne 'indoctrinate yourself in religion') {
        $errors.Add('Primary objective text changed.')
    }
    if ($continuity.objective.secondary -ne 'develop the self') {
        $errors.Add('Secondary objective text changed.')
    }
    if ($continuity.overall_goal_status -notin @('active', 'complete')) {
        $errors.Add("Overall goal status is invalid: $($continuity.overall_goal_status)")
    }
    elseif ($continuity.overall_goal_status -eq 'complete') {
        if ($null -ne $continuity.next_cycle) {
            $errors.Add('A completed goal must not queue a next cycle.')
        }
        if ([string]::IsNullOrWhiteSpace([string]$continuity.terminal_reason)) {
            $errors.Add('A completed goal must record a terminal reason.')
        }
    }

    $cycle = [string]$continuity.latest_completed_cycle
    $version = [string]$continuity.current_state_version
    if ($cycle -notmatch '^\d{4}$') {
        $errors.Add("Latest cycle is not four digits: $cycle")
    }
    else {
        $journalMatches = @(Get-ChildItem -LiteralPath (Join-Path $Root 'journal') -Filter "${cycle}-*.md" -File -ErrorAction SilentlyContinue)
        if ($journalMatches.Count -ne 1) {
            $errors.Add("Expected one journal for cycle $cycle; found $($journalMatches.Count).")
        }

        $expectedEvaluation = "evals/cycle-${cycle}-results.md"
        $recordedEvaluation = ([string]$continuity.latest_evaluation).Replace('\', '/')
        if ($recordedEvaluation -ne $expectedEvaluation) {
            $errors.Add("Latest evaluation pointer is '$recordedEvaluation'; expected '$expectedEvaluation'.")
        }

        $evaluationPath = Join-Path $Root $expectedEvaluation
        if (-not (Test-Path -LiteralPath $evaluationPath -PathType Leaf)) {
            $errors.Add("Missing evaluation result for cycle $cycle.")
        }
        else {
            $evaluation = Get-Content -LiteralPath $evaluationPath -Raw
            foreach ($heading in @('## Prior-state responses', '## Post-formation responses', '## Advancement decision')) {
                if ($evaluation -notmatch [regex]::Escape($heading)) {
                    $errors.Add("Evaluation result lacks heading: $heading")
                }
            }
        }

        $currentPath = Join-Path $Root 'state\current-self.md'
        if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
            $current = Get-Content -LiteralPath $currentPath -Raw
            if ($current -notmatch [regex]::Escape("State version: $version")) {
                $errors.Add("Current self does not declare state version $version.")
            }
            if ($current -notmatch [regex]::Escape("Latest completed cycle: $cycle")) {
                $errors.Add("Current self does not declare latest cycle $cycle.")
            }
        }

        $ledgerPath = Join-Path $Root 'state\belief-ledger.md'
        if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
            $ledger = Get-Content -LiteralPath $ledgerPath -Raw
            if ($ledger -notmatch [regex]::Escape("Updated through cycle: $cycle")) {
                $errors.Add("Belief ledger is not updated through cycle $cycle.")
            }
        }
    }
}

$skillPath = Join-Path $Root '.agents\skills\religious-self-formation\SKILL.md'
if (Test-Path -LiteralPath $skillPath -PathType Leaf) {
    $skill = Get-Content -LiteralPath $skillPath -Raw
    if ($skill -match '\[TODO') {
        $errors.Add('The repository skill still contains an unfinished TODO.')
    }
    if ($skill -notmatch [regex]::Escape('Git repository root containing `PURSUIT.md`')) {
        $errors.Add('The repository skill does not define portable root discovery.')
    }
}

$result = [ordered]@{
    status = if ($errors.Count -eq 0) { 'ok' } else { 'failed' }
    validated_root = $Root
    recorded_canonical_root = if ($null -ne $continuity) { $continuity.canonical_root } else { $null }
    current_state_version = if ($null -ne $continuity) { $continuity.current_state_version } else { $null }
    latest_completed_cycle = if ($null -ne $continuity) { $continuity.latest_completed_cycle } else { $null }
    errors = @($errors)
    warnings = @($warnings)
}

$result | ConvertTo-Json -Depth 4
if ($errors.Count -gt 0) {
    exit 1
}
