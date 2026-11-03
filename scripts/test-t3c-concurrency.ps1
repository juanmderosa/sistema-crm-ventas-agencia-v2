param(
    [switch]$CombinedOnly,
    [switch]$KeepDatabase,
    [string]$Container = 'supabase_db_dealership-mvp'
)

# This runner creates its own isolated database. Never target the application DB.
$ErrorActionPreference = 'Stop'
$Database = 't3c_regression_' + [guid]::NewGuid().ToString('N')
$scratch = Join-Path $env:TEMP ('opencode/' + $Database)
New-Item -ItemType Directory -Path $scratch | Out-Null
$env:HOME = $scratch
$env:TMPDIR = $scratch

function Sql([string]$Text) {
    $output = $Text | docker exec -i $Container psql -X -At -U postgres -v ON_ERROR_STOP=1 $Database 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return ($output -join "`n")
}
function StartSession([string]$Name, [string]$Text) {
    $info = [Diagnostics.ProcessStartInfo]::new('docker', "exec -i $Container psql -X -At -U postgres -v ON_ERROR_STOP=1 $Database")
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.WriteLine("\set VERBOSITY verbose`nset statement_timeout='15s'; set application_name='$Name'; $Text")
    $process.StandardInput.Flush()
    return @{ Process = $process; Output = $output; Errors = $errors }
}
function WaitState([string]$Name, [string]$Predicate) {
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        if ((Sql "select count(*) from pg_stat_activity where datname=current_database() and application_name='$Name' and ($Predicate);") -eq '1') { return }
        Start-Sleep -Milliseconds 75
    }
    throw "No observed concurrent state: $Name $Predicate"
}
function Finish($Session) {
    $Session.Process.StandardInput.Close()
    if (-not $Session.Process.WaitForExit(20000)) { throw 'Concurrent session timed out' }
    return @{ Code = $Session.Process.ExitCode; Output = $Session.Output.Result; Errors = $Session.Errors.Result }
}
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Actor([string]$Id) { return "set role authenticated; set request.jwt.claim.sub='$Id';" }

$owner = '10000000-0000-0000-0000-000000000001'
$seller = '10000000-0000-0000-0000-000000000002'
$c1 = '20000000-0000-0000-0000-000000000001'
$c2 = '20000000-0000-0000-0000-000000000002'
$v1 = '30000000-0000-0000-0000-000000000001'
$v2 = '30000000-0000-0000-0000-000000000002'
$inquiry = '40000000-0000-0000-0000-000000000001'
$hash = "select 'HASH:'||md5(string_agg(t,'|' order by t)) from (select row_to_json(x)::text t from public.contacts x union all select row_to_json(x)::text from public.inquiries x union all select row_to_json(x)::text from public.inquiry_interests x union all select row_to_json(x)::text from public.inquiry_assignment_history x union all select row_to_json(x)::text from public.vehicle_inquiry_rotation x union all select row_to_json(x)::text from public.vehicles x) z;"

function Race([string]$Name, [string]$Winner, [string]$Loser, [string]$ExpectedError, [bool]$Preserve = $true) {
    $first = StartSession "${Name}_first" "begin; $Winner reset role; $hash"
    WaitState "${Name}_first" "state='idle in transaction'"
    $second = StartSession "${Name}_second" $Loser
    WaitState "${Name}_second" "wait_event_type='Lock'"
    $first.Process.StandardInput.WriteLine('commit;')
    $first.Process.StandardInput.Flush()
    $winnerResult = Finish $first
    $loserResult = Finish $second
    Assert ($winnerResult.Code -eq 0) "Winner failed: $($winnerResult.Errors)"
    Assert ($loserResult.Errors -notmatch '40P01:') 'Unexpected deadlock'
    if ($ExpectedError) {
        Assert ($loserResult.Code -eq 3 -and $loserResult.Errors -match $ExpectedError) "Unexpected loser result: $($loserResult.Errors)"
    } else { Assert ($loserResult.Code -eq 0) "Second operation failed: $($loserResult.Errors)" }
    if ($Preserve) {
        $expectedHash = @($winnerResult.Output -split "`r?`n" | Where-Object { $_ -like 'HASH:*' })[-1]
        Assert ((Sql $hash) -eq $expectedHash) 'Rejected operation changed stored rows'
    }
    Write-Output "$Name PASS (observed overlapping lock wait)"
}

docker exec $Container createdb -U postgres $Database
if ($LASTEXITCODE -ne 0) { throw 'Could not create isolated test database' }
Write-Output "Database: $Database; scratch: $scratch"
try {
    Sql @"
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as 'select nullif(current_setting(''request.jwt.claim.sub'',true),'''')::uuid';
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
"@ | Out-Null
    $migrations = Join-Path $PSScriptRoot '../supabase/migrations'
    Get-ChildItem "$migrations/*.sql" | Sort-Object Name | ForEach-Object { Sql (Get-Content $_.FullName -Raw) | Out-Null }
    Sql @"
insert into auth.users values ('$owner'),('$seller');
insert into public.profiles(id,role,display_name) values ('$owner','owner','Owner'),('$seller','seller','Seller');
insert into public.vehicles(id,brand,model,year,publication_status) values ('$v1','Test','One',2024,'published'),('$v2','Test','Two',2024,'published');
insert into public.contacts(id,normalized_phone,display_name,email) values ('$c1','+54110001','Original','old@example.invalid'),('$c2','+54110002','Second','second@example.invalid');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_email,submitted_phone) values ('$inquiry','$inquiry','$c1','$v1','$seller','Snapshot','snapshot@example.invalid','+54110001');
insert into public.inquiry_interests(inquiry_id,vehicle_id) values ('$inquiry','$v1');
"@ | Out-Null
    $actor = Actor $owner
    if (-not $CombinedOnly) {
        Race 'details_details' "$actor select public.update_contact_details('$c1',0,'Winner','winner@example.invalid');" "$actor select public.update_contact_details('$c1',0,'Loser','loser@example.invalid');" '40001: contact changed; reload the contact and retry'
        Race 'details_phone' "$actor select public.update_contact_details('$c1',1,'Final','final@example.invalid');" "$actor select public.update_contact_phone('$c1',1,'+54119999');" '40001: contact changed; reload the contact and retry'
        Race 'phone_collision' "$actor select public.update_contact_phone('$c1',2,'+54118888');" "$actor select public.update_contact_phone('$c2',0,'+54118888');" '23505: phone already belongs to another contact'
        Race 'phone_submit' "$actor select public.update_contact_phone('$c1',3,'+54117777');" "set role service_role; select public.submit_inquiry('50000000-0000-0000-0000-000000000001','$v1','+54117777','Submitted','submitted@example.invalid');" '' $false
        Race 'closure_interest' "update public.inquiries set status='closed_without_sale' where id='$inquiry';" "$(Actor $seller) select public.add_inquiry_interest('$inquiry','$v2');" '22023: inquiry is not active'
        Sql "update public.inquiries set status='new' where id='$inquiry';" | Out-Null
        Race 'reassign_interest' "update public.inquiries set assignee_id='$owner' where id='$inquiry';" "$(Actor $seller) select public.add_inquiry_interest('$inquiry','$v2');" '42501: inquiry interest access denied'
    }

    # Regression: details holds its phone key before a phone edit can hold the row.
    $revision = Sql "select revision from public.contacts where id='$c1';"
    $phone = Sql "select normalized_phone from public.contacts where id='$c1';"
    $submission = [guid]::NewGuid().ToString()
    $first = StartSession 'combined_details_submit' "begin; $actor select public.update_contact_details('$c1',$revision,'Combined','combined@example.invalid');"
    WaitState 'combined_details_submit' "state='idle in transaction'"
    $second = StartSession 'combined_phone' "$actor select public.update_contact_phone('$c1',$revision,'+54115555');"
    WaitState 'combined_phone' "wait_event_type='Lock'"
    $first.Process.StandardInput.WriteLine("set role service_role; select public.submit_inquiry('$submission','$v1','$phone','Combined','combined@example.invalid'); reset role; $hash commit;")
    $first.Process.StandardInput.Flush()
    $winner = Finish $first
    $loser = Finish $second
    Assert ($winner.Code -eq 0) "Combined transaction failed: $($winner.Errors)"
    Assert ($loser.Code -eq 3 -and $loser.Errors -match '40001: contact changed; reload the contact and retry') "Phone edit did not report a stale version: $($loser.Errors)"
    Assert (($winner.Errors + $loser.Errors) -notmatch '40P01:') 'Combined transaction deadlocked'
    $expected = @($winner.Output -split "`r?`n" | Where-Object { $_ -like 'HASH:*' })[-1]
    Assert ((Sql $hash) -eq $expected) 'Rejected phone edit changed stored rows'
    Write-Output 'combined_details_submit PASS (observed overlap, no deadlock, stale edit rejected)'
} finally {
    if (-not $KeepDatabase) {
        docker exec $Container dropdb -U postgres --force $Database
        if ($LASTEXITCODE -ne 0) { Write-Warning "Cleanup pending: $Database" }
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
