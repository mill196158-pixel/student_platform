Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SnapshotDir = Join-Path $ProjectRoot "docs\_snapshots"

New-Item -ItemType Directory -Force -Path $SnapshotDir | Out-Null

function Write-TextFile {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Body
  )

  $Path = Join-Path $SnapshotDir $Name
  try {
    & $Body | Out-File -FilePath $Path -Encoding utf8
  } catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $Path -Encoding utf8
  }
}

function Write-Tree {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [int]$Depth = 4
  )

  Write-TextFile $Name {
    $Root = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path $Root)) {
      "MISSING: $RelativePath"
      return
    }

    Get-ChildItem -LiteralPath $Root -Recurse -Depth $Depth -Force |
      Where-Object {
        $_.FullName -notmatch '\\\.git\\' -and
        $_.FullName -notmatch '\\build\\' -and
        $_.FullName -notmatch '\\\.dart_tool\\' -and
        $_.FullName -notmatch '\\node_modules\\'
      } |
      Sort-Object FullName |
      ForEach-Object {
        $_.FullName.Substring($ProjectRoot.Length + 1)
      }
  }
}

function Write-Search {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Patterns,
    [string[]]$Include = @("*.dart", "*.js", "*.ts", "*.sql", "*.md", "*.yaml", "*.yml", "*.json")
  )

  Write-TextFile $Name {
    $SearchRoots = @(
      (Join-Path $ProjectRoot "lib"),
      (Join-Path $ProjectRoot "scripts"),
      (Join-Path $ProjectRoot "supabase")
    ) | Where-Object { Test-Path $_ }

    foreach ($Pattern in $Patterns) {
      "## PATTERN: $Pattern"
      foreach ($Root in $SearchRoots) {
        Get-ChildItem -LiteralPath $Root -Recurse -File -Include $Include -ErrorAction SilentlyContinue |
          Where-Object {
            $_.FullName -notmatch '\\\.env' -and
            $_.FullName -notmatch '\\node_modules\\' -and
            $_.FullName -notmatch '\\build\\'
          } |
          Select-String -Pattern $Pattern -SimpleMatch -ErrorAction SilentlyContinue |
          ForEach-Object {
            $Rel = $_.Path.Substring($ProjectRoot.Length + 1)
            "${Rel}:$($_.LineNumber):$($_.Line.Trim())"
          }
      }
      ""
    }
  }
}

Push-Location $ProjectRoot
try {
  Write-TextFile "git_status.txt" { git status --short }
  Write-TextFile "git_branch.txt" { git branch --show-current }
  Write-TextFile "git_remote.txt" { git remote -v }
  Write-TextFile "project_tree_top.txt" {
    Get-ChildItem -LiteralPath $ProjectRoot -Force |
      Sort-Object Name |
      ForEach-Object { $_.Name }
  }
  Write-TextFile "pubspec_head.txt" {
    Get-Content -LiteralPath (Join-Path $ProjectRoot "pubspec.yaml") -TotalCount 120
  }

  Write-Tree "lib_tree.txt" "lib" 6
  Write-Tree "screens_tree.txt" "lib\src\ui" 6
  Write-Tree "services_tree.txt" "lib\src\services" 4
  Write-Tree "models_tree.txt" "lib\src" 6
  Write-Tree "repositories_tree.txt" "lib\src" 6
  Write-Tree "blocs_cubits_tree.txt" "lib\src" 6
  Write-Tree "supabase_tree.txt" "supabase" 6
  Write-Tree "scripts_tree.txt" "scripts" 5
  Write-Tree "docs_tree.txt" "docs" 5

  Write-Search "supabase_from_usage.txt" @("Supabase.instance", "supabase", ".from(")
  Write-Search "supabase_auth_usage.txt" @("auth.")
  Write-Search "supabase_storage_usage.txt" @("storage.from")
  Write-Search "supabase_rpc_usage.txt" @(".rpc(")
  Write-Search "navigator_usage.txt" @("Navigator.push", "Navigator.of", "MaterialPageRoute")
  Write-Search "router_usage.txt" @("GoRouter", "context.go", "ShellRoute")
  Write-Search "academic_terms_usage.txt" @("academic_years", "academic_terms", "group_academic_profiles", "group_term_semesters", "student_enrollments", "subject_offerings", "subject_catalog", "curriculum_subjects")
  Write-Search "table_terms_usage.txt" @("groups", "teams", "team_members", "chats", "chat_members", "messages", "chat_files", "users", "student_enrollments", "subject_offerings", "subject_catalog", "curriculum_subjects", "schedule", "lessons", "assignments", "diary", "friends", "useful")
} finally {
  Pop-Location
}

"Snapshot written to $SnapshotDir"
