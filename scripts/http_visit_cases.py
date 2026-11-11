"""Visit and profile permission cases using genuinely issued user JWTs."""
import uuid


def run_visit_probes(env):
    check, sql, rpc, call = (env[k] for k in ('check', 'sql', 'rpc', 'call'))
    denied, snapshot = env['denied'], env['state_hash']
    users, tokens, anon, service = (env[k] for k in ('users', 'tokens', 'ANON', 'SERVICE'))
    vehicle, inquiry = env['V_PUB'], env['inquiry_id']
    own = env['assignee_role']
    other = 'seller2' if own == 'seller1' else 'seller1'

    def unchanged(name, action):
        before = snapshot()
        code, body = action()
        denied(name, code, body)
        check(name + ' preserves all public data', snapshot() == before)

    for target in ('owner', 'admin'):
        unchanged('H Admin cannot grant ' + target, lambda: call(
            'PATCH', '/rest/v1/profiles?id=eq.' + users[own], key=anon, token=tokens['admin'],
            body={'role': target}, extra={'Prefer': 'return=representation'}))
    code, body = call('PATCH', '/rest/v1/profiles?id=eq.' + users['admin'], key=anon,
                      token=tokens['admin'], body={'display_name': 'HTTP Admin renamed'},
                      extra={'Prefer': 'return=representation'})
    check('H Admin self rename persists over HTTP', code == 200 and len(body) == 1
          and sql("select display_name from public.profiles where id='%s'" % users['admin']) == 'HTTP Admin renamed')
    before = snapshot()
    code, body = call('PATCH', '/rest/v1/profiles?id=eq.' + users['owner'], key=anon,
                      token=tokens['admin'], body={'display_name': 'Forbidden'},
                      extra={'Prefer': 'return=representation'})
    check('H Admin cannot modify Owner over HTTP', code == 200 and body == [] and snapshot() == before)

    hours = {'p_intervals': [{'weekday': n, 'opens_at': '00:00', 'closes_at': '24:00'} for n in range(7)]}
    code, detail = rpc('set_dealership_opening_hours', tokens['owner'], hours)
    check('H Owner configures isolated opening hours over HTTP', code in (200, 204))
    if code not in (200, 204):
        print('Opening-hours prerequisite HTTP=%d code=%s' % (code, detail.get('code') if isinstance(detail, dict) else 'unknown'))
        if isinstance(detail, dict) and detail.get('code') == '21000':
            print('Opening-hours cardinality diagnosis:', detail.get('message'))
    slot = sql("select clock_timestamp()+interval '7 days'")
    slot2 = sql("select '%s'::timestamptz+interval '1 hour'" % slot)
    payload = {'p_submission_id': str(uuid.uuid4()), 'p_inquiry_id': inquiry,
               'p_vehicle_id': vehicle, 'p_scheduled_at': slot, 'p_purpose': 'HTTP visit'}
    code, body = rpc('create_inquiry_visit', tokens[own], payload)
    check('H Responsible seller creates visit with genuine JWT', code == 200 and isinstance(body, dict) and set(body) == {'visit_id'})
    if code != 200 or not isinstance(body, dict) or 'visit_id' not in body:
        print('Visit prerequisite HTTP=%d code=%s' % (code, body.get('code') if isinstance(body, dict) else 'unknown'))
        raise RuntimeError('visit fixture failed; response suppressed')
    visit = body['visit_id']
    before = snapshot()
    check('H Private visit retry is immutable over HTTP', rpc('create_inquiry_visit', tokens[own], payload) == (200, body) and snapshot() == before)
    check('H One visit and creation event persisted', sql("select count(*) from public.visit_history where visit_id='%s'" % visit) == '1')

    public_payload = {'p_submission_id': str(uuid.uuid4()), 'p_vehicle_id': vehicle,
                      'p_phone': env['PHONE_A'], 'p_name': 'HTTP public visit',
                      'p_email': 'visit@example.invalid', 'p_scheduled_at': slot}
    state = {'p_visit_id': visit, 'p_status': 'confirmed'}
    reschedule = {'p_visit_id': visit, 'p_scheduled_at': slot2, 'p_agreed': True}
    period = {'p_kind': 'month', 'p_start': env['START']}
    operations = [('set_dealership_opening_hours', hours), ('create_inquiry_visit', payload),
                  ('submit_visit_request', public_payload), ('set_visit_status', state),
                  ('reschedule_visit', reschedule), ('get_visit_reporting_summary', period),
                  ('get_my_visit_reporting_summary', period)]
    for name, params in operations:
        unchanged('H Anonymous denied ' + name, lambda n=name, p=params: rpc(n, None, p))
        if name != 'submit_visit_request':
            unchanged('H Service denied ' + name, lambda n=name, p=params: rpc(n, service, p, key=service))
    for identity in (other, 'ghost', 'inactive'):
        for name, params in [('create_inquiry_visit', dict(payload, p_submission_id=str(uuid.uuid4()))),
                             ('set_visit_status', state), ('reschedule_visit', reschedule)]:
            unchanged('H ' + identity + ' denied ' + name,
                      lambda n=name, p=params, who=identity: rpc(n, tokens[who], p))
    for name, params in [('set_dealership_opening_hours', hours), ('submit_visit_request', public_payload),
                         ('get_visit_reporting_summary', period)]:
        unchanged('H Seller denied ' + name, lambda n=name, p=params: rpc(n, tokens[own], p))
    for table in ('visits', 'visit_history', 'visit_creation_requests', 'dealership_opening_hours'):
        unchanged('H Anonymous cannot read ' + table, lambda t=table: call('GET', '/rest/v1/' + t, key=anon))
    for who in (other, 'ghost', 'inactive'):
        for table in ('visits', 'visit_history'):
            key = 'id' if table == 'visits' else 'visit_id'
            code, body = call('GET', '/rest/v1/%s?%s=eq.%s' % (table, key, visit), key=anon, token=tokens[who])
            check('H ' + who + ' has no ' + table + ' detail', code == 200 and body == [])
    for who in (own, 'owner', 'admin'):
        code, body = call('GET', '/rest/v1/visits?id=eq.' + visit, key=anon, token=tokens[who])
        check('H ' + who + ' reads authorized visit', code == 200 and len(body) == 1 and body[0]['id'] == visit)
    check('H Responsible seller confirms visit', rpc('set_visit_status', tokens[own], state)[0] == 200
          and sql("select status from public.visits where id='%s'" % visit) == 'confirmed')
    check('H Admin reschedules visit', rpc('reschedule_visit', tokens['admin'], reschedule)[0] == 200
          and sql("select scheduled_at='%s'::timestamptz from public.visits where id='%s'" % (slot2, visit)) == 't')
    check('H Responsible seller cancels visit', rpc('set_visit_status', tokens[own], {'p_visit_id': visit, 'p_status': 'cancelled'})[0] == 200)
    check('H Owner corrects current result', rpc('set_visit_status', tokens['owner'], {
        'p_visit_id': visit, 'p_status': 'attended', 'p_reason': 'Correct HTTP result'})[0] == 200)
    scheduled_day = sql("select to_char(scheduled_at at time zone 'America/Argentina/Buenos_Aires','YYYY-MM-DD') from public.visits where id='%s'" % visit)
    period = {'p_kind': 'custom', 'p_start': min(env['START'], scheduled_day), 'p_end': max(env['START'], scheduled_day)}
    for who in ('owner', 'admin'):
        code, body = rpc('get_visit_reporting_summary', tokens[who], period)
        check('H ' + who + ' global visit figures', code == 200 and body.get('totals') == {
            'requests': 1, 'attended': 1, 'cancelled': 0, 'no_show': 0})
    sql("update public.inquiries set assignee_id='%s' where id='%s'" % (users[other], inquiry))
    code, body = rpc('get_my_visit_reporting_summary', tokens[own], period)
    check('H Former assignee retains only own historical figures', code == 200
          and set(body) == {'period', 'figures', 'scope'} and body['scope'] == {'subject': 'self'}
          and body['figures'] == {'requests': 1, 'attended': 1, 'cancelled': 0, 'no_show': 0})
    code, body = call('GET', '/rest/v1/visits?id=eq.' + visit, key=anon, token=tokens[own])
    check('H Former assignee cannot inspect visit details', code == 200 and body == [])
    code, body = rpc('submit_visit_request', service, public_payload, key=service)
    check('H Trusted public visit returns accepted-only response', (code, body) == (200, {'accepted': True}))
    before = snapshot()
    check('H Trusted public visit retry adds no data', rpc('submit_visit_request', service, public_payload, key=service)
          == (200, {'accepted': True}) and snapshot() == before)
    check('H Public visit creates one new visit', sql('select count(*) from public.visits') == '2')
    check('H Owner blocks vehicle through HTTP', rpc('set_vehicle_sale_blocked', tokens['owner'], {'p_vehicle_id': vehicle, 'p_blocked': True})[0] == 200)
    check('H Blocking cancels only pending visit and retains current final result',
          sql("select count(*) from public.visits where status='cancelled'") == '1'
          and sql("select status from public.visits where id='%s'" % visit) == 'attended')
