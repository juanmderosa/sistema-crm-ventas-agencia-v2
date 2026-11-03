param(
    [switch]$KeepDatabase,
    [string]$Container = 'supabase_db_dealership-mvp'
)

# This runner creates its own isolated database. Never target the application DB.
$ErrorActionPreference = 'Stop'
$Database = 't4b_regression_' + [guid]::NewGuid().ToString('N')
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
    $process.StandardInput.WriteLine("\set VERBOSITY verbose`nset statement_timeout='20s'; set application_name='$Name'; $Text")
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
$seller3 = '10000000-0000-0000-0000-000000000003'
$seller4 = '10000000-0000-0000-0000-000000000004'
$c1 = '20000000-0000-0000-0000-000000000001'
$c2 = '20000000-0000-0000-0000-000000000002'
$v1 = '30000000-0000-0000-0000-000000000001'
$v3 = '30000000-0000-0000-0000-000000000003'
$v4 = '30000000-0000-0000-0000-000000000004'
$v5 = '30000000-0000-0000-0000-000000000005'
$v6 = '30000000-0000-0000-0000-000000000006'
$v7 = '30000000-0000-0000-0000-000000000007'
$i1 = '40000000-0000-0000-0000-000000000001'
$i2 = '40000000-0000-0000-0000-000000000002'
$i3 = '40000000-0000-0000-0000-000000000003'
$i4 = '40000000-0000-0000-0000-000000000004'
$i5 = '40000000-0000-0000-0000-000000000005'
$i6 = '40000000-0000-0000-0000-000000000006'
$i7 = '40000000-0000-0000-0000-000000000007'
$hash = "select 'HASH:'||md5(string_agg(t,'|' order by t)) from (select row_to_json(x)::text t from public.vehicles x union all select row_to_json(x)::text from public.inquiries x union all select row_to_json(x)::text from public.inquiry_interests x union all select row_to_json(x)::text from public.reservations x union all select row_to_json(x)::text from public.inquiry_assignment_history x) z;"

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
insert into auth.users values ('$owner'),('$seller3'),('$seller4');
insert into public.profiles(id,role,display_name) values
  ('$owner','owner','Owner'),('$seller3','seller','Seller Three'),('$seller4','seller','Seller Four');
insert into public.vehicles(id,brand,model,year,publication_status,availability_status) values
  ('$v1','Test','One',2024,'published','available'),('$v3','Test','Three',2024,'published','available'),
  ('$v4','Test','Four',2024,'published','available'),('$v5','Test','Five',2024,'published','available'),
  ('$v6','Test','Six',2024,'published','available'),('$v7','Test','Seven',2024,'published','available');
insert into public.contacts(id,normalized_phone,display_name,email) values
  ('$c1','+54110001','Contact One','one@example.invalid'),('$c2','+54110002','Contact Two','two@example.invalid');
insert into public.inquiries(id,submission_id,contact_id,originating_vehicle_id,assignee_id,submitted_name,submitted_email,submitted_phone) values
  ('$i1','$i1','$c1','$v1','$seller3','One','one@example.invalid','+54110001'),
  ('$i2','$i2','$c2','$v1','$seller4','Two','two@example.invalid','+54110002'),
  ('$i3','$i3','$c1','$v3','$owner','Three','one@example.invalid','+54110001'),
  ('$i4','$i4','$c1','$v5','$seller3','Four','one@example.invalid','+54110001'),
  ('$i5','$i5','$c2','$v5','$seller4','Five','two@example.invalid','+54110002'),
  ('$i6','$i6','$c1','$v6','$seller3','Six','one@example.invalid','+54110001'),
  ('$i7','$i7','$c1','$v7','$seller3','Seven','one@example.invalid','+54110001');
insert into public.inquiry_interests(inquiry_id,vehicle_id) values
  ('$i1','$v1'),('$i2','$v1'),('$i3','$v3'),('$i3','$v4'),('$i4','$v5'),('$i5','$v5'),
  ('$i6','$v6'),('$i7','$v7');
"@ | Out-Null
    $ownerActor = Actor $owner
    Sql "$ownerActor select public.reserve_inquiry_vehicle('$i4','$v5');" | Out-Null
    Sql "$ownerActor select public.reserve_inquiry_vehicle('$i6','$v6');" | Out-Null
    $resC = Sql "select id from public.reservations where vehicle_id='$v5' and status='active';"
    $resD = Sql "select id from public.reservations where vehicle_id='$v6' and status='active';"

    Race 'vehicle_collision' "$(Actor $seller3) select public.reserve_inquiry_vehicle('$i1','$v1');" `
        "$(Actor $seller4) select public.reserve_inquiry_vehicle('$i2','$v1');" `
        '22023: vehicle must be Available and enabled for sale'
    Race 'inquiry_collision' "$(Actor $owner) select public.reserve_inquiry_vehicle('$i3','$v3');" `
        "$(Actor $owner) select public.reserve_inquiry_vehicle('$i3','$v4');" `
        '23505: an active reservation already exists'
    Race 'cancel_then_reserve' "$(Actor $owner) select public.cancel_reservation('$resC');" `
        "$(Actor $seller4) select public.reserve_inquiry_vehicle('$i5','$v5');" '' $false
    Race 'double_cancel' "$(Actor $owner) select public.cancel_reservation('$resD');" `
        "$(Actor $owner) select public.cancel_reservation('$resD');" `
        '22023: reservation is not active'
    Race 'reserve_vs_availability' "$(Actor $seller3) select public.reserve_inquiry_vehicle('$i7','$v7');" `
        "set role service_role; update public.vehicles set availability_status='sold' where id='$v7';" `
        '22023: cancel the active reservation before changing availability'

    Assert ((Sql "select count(*) from public.reservations where vehicle_id='$v1' and status='active';") -eq '1') 'Vehicle collision kept a second reservation'
    Assert ((Sql "select availability_status from public.vehicles where id='$v1';") -eq 'reserved') 'Vehicle collision left the vehicle unreserved'
    Assert ((Sql "select count(*) from public.reservations where inquiry_id='$i3' and status='active';") -eq '1') 'Inquiry collision kept a second reservation'
    Assert ((Sql "select availability_status from public.vehicles where id='$v3';") -eq 'reserved') 'Inquiry collision left the vehicle unreserved'
    Assert ((Sql "select status from public.reservations where id='$resC';") -eq 'cancelled') 'Cancellation before reserve did not complete'
    Assert ((Sql "select count(*) from public.reservations where vehicle_id='$v5' and status='active';") -eq '1') 'Released vehicle was not reserved again'
    Assert ((Sql "select availability_status from public.vehicles where id='$v5';") -eq 'reserved') 'Released vehicle did not become reserved again'
    Assert ((Sql "select status from public.reservations where id='$resD';") -eq 'cancelled') 'Double cancel left the reservation active'
    Assert ((Sql "select availability_status from public.vehicles where id='$v6';") -eq 'available') 'Double cancel restored availability twice or not at all'
    Assert ((Sql "select count(*) from public.reservations where inquiry_id='$i7' and status='active';") -eq '1') 'Reserve-then-sell lost the reservation'
    Assert ((Sql "select availability_status from public.vehicles where id='$v7';") -eq 'reserved') 'Reserve-then-sell changed availability'
    Write-Output 'terminal state PASS (one active reservation per vehicle and per inquiry)'
} finally {
    if (-not $KeepDatabase) {
        docker exec $Container dropdb -U postgres --force $Database
        if ($LASTEXITCODE -ne 0) { Write-Warning "Cleanup pending: $Database" }
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}
