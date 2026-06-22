#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const VALID_STEPS = new Set(['all', 'preflight', 'auth', 'students', 'curriculum', 'teams', 'postcheck']);

function parseArgs(argv) {
  const args = {
    step: 'all',
    apply: false,
    dryRun: true,
    confirmFullImport: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--config') args.config = argv[++i];
    else if (arg === '--step') args.step = argv[++i];
    else if (arg === '--apply') {
      args.apply = true;
      args.dryRun = false;
    } else if (arg === '--dry-run') {
      args.dryRun = true;
      args.apply = false;
    } else if (arg === '--confirm-full-import') args.confirmFullImport = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }

  if (!args.help && !args.config) {
    throw new Error('Missing --config path');
  }
  if (!VALID_STEPS.has(args.step)) {
    throw new Error(`Invalid --step "${args.step}". Expected one of: ${Array.from(VALID_STEPS).join(', ')}`);
  }
  if (args.apply && args.step === 'all' && !args.confirmFullImport) {
    throw new Error('Apply mode with --step all requires --confirm-full-import');
  }
  return args;
}

function printHelp() {
  console.log(`
Academic batch import CLI

Usage:
  node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.example.json --step all --dry-run
  node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step auth --apply
  node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step students --apply
  node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step curriculum --apply
  node scripts/import_academic_batch.js --config scripts/import_configs/vv_2024.json --step teams --apply

Steps:
  preflight   Read-only staging and academic calendar checks
  auth        Create/update Auth credentials staging and Auth users through Admin API
  students    Fill public.users and student_enrollments
  curriculum  Create subject_catalog, subject_aliases, curriculum_subjects, subject_offerings
  teams       Create current-semester teams and memberships
  postcheck   Read-only final checks
  all         Run all dry-runs, or all apply steps with --confirm-full-import

Safety:
  Default mode is dry-run. Use --apply to change production data.
`);
}

function loadDotEnvLocal() {
  const envPath = path.resolve(process.cwd(), '.env.local');
  if (!fs.existsSync(envPath)) return;

  const content = fs.readFileSync(envPath, 'utf8');
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;

    const eq = trimmed.indexOf('=');
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    if (!process.env[key]) process.env[key] = value;
  }
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(path.resolve(filePath), 'utf8'));
}

function trimTrailingSlash(value) {
  return value.replace(/\/+$/, '');
}

function assertSafeIdentifier(value, label) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) {
    throw new Error(`Unsafe ${label}: ${value}`);
  }
}

function normalizeName(value) {
  const text = String(value || '').trim().toLowerCase().replace(/\s+/g, ' ');
  return text || null;
}

function isNonEmpty(value) {
  return value !== null && value !== undefined && String(value).trim() !== '';
}

function uniqueBy(items, keyFn) {
  const map = new Map();
  for (const item of items) {
    const key = keyFn(item);
    if (!map.has(key)) map.set(key, item);
  }
  return Array.from(map.values());
}

function groupCount(items, keyFn) {
  const map = new Map();
  for (const item of items) {
    const key = keyFn(item);
    map.set(key, (map.get(key) || 0) + 1);
  }
  return map;
}

function rowsWithDuplicates(items, keyFn) {
  const counts = groupCount(items, keyFn);
  return Array.from(counts.entries())
    .filter(([, count]) => count > 1)
    .map(([key, count]) => ({ key, count }));
}

class SupabaseRest {
  constructor(url, serviceRoleKey) {
    this.url = trimTrailingSlash(url);
    this.serviceRoleKey = serviceRoleKey;
    this.headers = {
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
      'content-type': 'application/json',
    };
  }

  tableUrl(table, query = '') {
    assertSafeIdentifier(table, 'table name');
    return `${this.url}/rest/v1/${table}${query}`;
  }

  async request(url, options = {}) {
    const response = await fetch(url, {
      ...options,
      headers: {
        ...this.headers,
        ...(options.headers || {}),
      },
    });
    const text = await response.text();
    let body = null;
    if (text) {
      try {
        body = JSON.parse(text);
      } catch {
        body = { message: text };
      }
    }
    if (!response.ok) {
      const message = body?.message || body?.msg || body?.error || body?.hint || `HTTP ${response.status}`;
      const error = new Error(message);
      error.status = response.status;
      error.body = body;
      throw error;
    }
    return body;
  }

  async list(table, select = '*') {
    const params = new URLSearchParams({ select });
    return this.request(this.tableUrl(table, `?${params}`), {
      method: 'GET',
      headers: { prefer: 'count=exact' },
    });
  }

  async insert(table, rows, options = {}) {
    if (!rows.length) return [];
    const query = options.onConflict ? `?on_conflict=${encodeURIComponent(options.onConflict)}` : '';
    const prefer = [
      options.merge ? 'resolution=merge-duplicates' : null,
      options.ignore ? 'resolution=ignore-duplicates' : null,
      options.returnMinimal ? 'return=minimal' : 'return=representation',
    ].filter(Boolean).join(',');

    const body = await this.request(this.tableUrl(table, query), {
      method: 'POST',
      headers: { prefer },
      body: JSON.stringify(rows),
    });
    return Array.isArray(body) ? body : [];
  }

  async patchById(table, id, patch) {
    const query = `?id=eq.${encodeURIComponent(id)}`;
    await this.request(this.tableUrl(table, query), {
      method: 'PATCH',
      headers: { prefer: 'return=minimal' },
      body: JSON.stringify(patch),
    });
  }

  async patchByFilter(table, filters, patch) {
    const params = new URLSearchParams();
    for (const [key, value] of Object.entries(filters)) {
      params.set(key, `eq.${value}`);
    }
    await this.request(this.tableUrl(table, `?${params}`), {
      method: 'PATCH',
      headers: { prefer: 'return=minimal' },
      body: JSON.stringify(patch),
    });
  }

  async createAuthUser(payload) {
    return this.request(`${this.url}/auth/v1/admin/users`, {
      method: 'POST',
      body: JSON.stringify(payload),
    });
  }

  async listAuthUsers() {
    const users = [];
    for (let page = 1; page <= 20; page += 1) {
      const params = new URLSearchParams({ page: String(page), per_page: '1000' });
      const body = await this.request(`${this.url}/auth/v1/admin/users?${params}`, { method: 'GET' });
      const pageUsers = Array.isArray(body?.users) ? body.users : Array.isArray(body) ? body : [];
      users.push(...pageUsers);
      if (pageUsers.length < 1000) break;
    }
    return users;
  }
}

function makeContext(config, db) {
  for (const [field, label] of [
    ['students_stage_table', 'students_stage_table'],
    ['curriculum_stage_table', 'curriculum_stage_table'],
    ['auth_credentials_stage_table', 'auth_credentials_stage_table'],
  ]) {
    assertSafeIdentifier(config[field], label);
  }
  return { config, db, cache: {} };
}

async function loadCommon(ctx) {
  const { config, db, cache } = ctx;
  if (cache.common) return cache.common;

  const [students, curriculum, credentials, users, groups, enrollments, years, terms, groupTerms] = await Promise.all([
    db.list(config.students_stage_table).catch((error) => ({ __error: error })),
    db.list(config.curriculum_stage_table).catch((error) => ({ __error: error })),
    db.list(config.auth_credentials_stage_table).catch((error) => ({ __error: error })),
    db.list('users'),
    db.list('groups'),
    db.list('student_enrollments'),
    db.list('academic_years'),
    db.list('academic_terms'),
    db.list('group_term_semesters'),
  ]);

  cache.common = { students, curriculum, credentials, users, groups, enrollments, years, terms, groupTerms };
  return cache.common;
}

function tableMissing(value) {
  return value && value.__error;
}

function rowsOrEmpty(value) {
  return Array.isArray(value) ? value : [];
}

function loginOf(row) {
  return String(row.login || '').trim();
}

function emailForLogin(login, config) {
  return `${String(login).trim().toLowerCase()}@${config.technical_email_domain}`;
}

function passwordFor(row, config) {
  if (config.initial_password_strategy !== 'login') {
    throw new Error(`Unsupported initial_password_strategy: ${config.initial_password_strategy}`);
  }
  return loginOf(row);
}

function summarizeBlocked(label, blockedRows) {
  return {
    label,
    blocked: blockedRows.length,
    rows: blockedRows.slice(0, 20),
  };
}

async function preflightSummary(ctx) {
  const { config } = ctx;
  const common = await loadCommon(ctx);
  const students = rowsOrEmpty(common.students);
  const curriculum = rowsOrEmpty(common.curriculum);
  const groups = rowsOrEmpty(common.groups);
  const years = rowsOrEmpty(common.years);
  const terms = rowsOrEmpty(common.terms);
  const groupTerms = rowsOrEmpty(common.groupTerms);

  const missingTables = [];
  if (tableMissing(common.students)) missingTables.push(config.students_stage_table);
  if (tableMissing(common.curriculum)) missingTables.push(config.curriculum_stage_table);
  if (tableMissing(common.credentials)) missingTables.push(config.auth_credentials_stage_table);

  const duplicateLogins = rowsWithDuplicates(students.filter((s) => isNonEmpty(s.login)), (s) => loginOf(s).toLowerCase());
  const duplicateRecordBooks = rowsWithDuplicates(students.filter((s) => isNonEmpty(s.record_book)), (s) => String(s.record_book).trim().toLowerCase());
  const groupSet = new Set(groups.map((g) => g.name));
  const missingGroups = config.groups.filter((name) => !groupSet.has(name));
  const year = years.find((row) => row.name === config.current_academic_year);
  const termByCode = terms.find((row) => String(row.term_sequence) === String(config.current_term_code));
  const targetGroups = groups.filter((g) => config.groups.includes(g.name));
  const groupTermMissing = [];
  for (const group of targetGroups) {
    const found = groupTerms.some((gt) => gt.group_id === group.id && Number(gt.semester_number) === Number(config.current_semester_number));
    if (!found) groupTermMissing.push(group.name);
  }

  const blockedRows = [];
  for (const name of missingTables) blockedRows.push({ reason: 'missing_stage_table', table: name });
  for (const item of duplicateLogins) blockedRows.push({ reason: 'duplicate_login', ...item });
  for (const item of duplicateRecordBooks) blockedRows.push({ reason: 'duplicate_record_book', ...item });
  for (const name of missingGroups) blockedRows.push({ reason: 'missing_group', group_name: name });
  if (!year) blockedRows.push({ reason: 'missing_academic_year', academic_year: config.current_academic_year });
  if (!termByCode) blockedRows.push({ reason: 'missing_academic_term_code', current_term_code: config.current_term_code });
  for (const name of groupTermMissing) blockedRows.push({ reason: 'missing_group_term_semester', group_name: name });

  return {
    step: 'preflight',
    stageStudents: students.length,
    stageCurriculum: curriculum.length,
    credentialsRows: rowsOrEmpty(common.credentials).length,
    groupsConfigured: config.groups.length,
    duplicateLogins: duplicateLogins.length,
    duplicateRecordBooks: duplicateRecordBooks.length,
    missingGroups,
    academicYearFound: Boolean(year),
    academicTermFound: Boolean(termByCode),
    missingGroupTermSemesters: groupTermMissing,
    blocked: blockedRows.length,
    blockedDetails: blockedRows.slice(0, 20),
  };
}

async function authSummary(ctx) {
  const { config, db } = ctx;
  const common = await loadCommon(ctx);
  const students = rowsOrEmpty(common.students);
  const credentials = rowsOrEmpty(common.credentials);
  const authUsers = await db.listAuthUsers().catch(() => []);
  const authEmails = new Set(authUsers.map((u) => String(u.email || '').toLowerCase()));
  const credentialByLogin = new Map(credentials.map((c) => [String(c.login || '').toLowerCase(), c]));

  const credentialRowsToCreate = students.filter((s) => !credentialByLogin.has(loginOf(s).toLowerCase()));
  const authUsersToCreate = students.filter((s) => {
    const login = loginOf(s);
    const cred = credentialByLogin.get(login.toLowerCase());
    return login && !(cred?.created_in_auth && cred?.auth_user_id) && !authEmails.has(emailForLogin(login, config));
  });
  const existingAuthUsersByEmail = students.filter((s) => authEmails.has(emailForLogin(loginOf(s), config)));
  const duplicateLogins = rowsWithDuplicates(students.filter((s) => isNonEmpty(s.login)), (s) => loginOf(s).toLowerCase());
  const emptyLogin = students.filter((s) => !isNonEmpty(s.login));
  const blockedRows = [
    ...duplicateLogins.map((d) => ({ reason: 'duplicate_login', ...d })),
    ...emptyLogin.map((s) => ({ reason: 'empty_login', source_row: s.source_row })),
  ];

  return {
    step: 'auth',
    credentialsTableAvailable: !tableMissing(common.credentials),
    stageStudents: students.length,
    credentialRowsToCreate: credentialRowsToCreate.length,
    authUsersToCreate: authUsersToCreate.length,
    existingAuthUsersByEmail: existingAuthUsersByEmail.length,
    credentialsCreatedInAuth: credentials.filter((c) => c.created_in_auth).length,
    credentialsWithErrors: credentials.filter((c) => isNonEmpty(c.error_message)).length,
    blocked: tableMissing(common.credentials) ? blockedRows.length + 1 : blockedRows.length,
    blockedDetails: [
      ...(tableMissing(common.credentials) ? [{ reason: 'missing_auth_credentials_stage_table', table: config.auth_credentials_stage_table }] : []),
      ...blockedRows.slice(0, 20),
    ],
  };
}

async function applyAuth(ctx) {
  const { config, db } = ctx;
  const summary = await authSummary(ctx);
  printSummary(summary);
  if (summary.blocked > 0) throw new Error('Auth apply blocked. Fix blocked rows first.');

  const common = await loadCommon(ctx);
  const students = rowsOrEmpty(common.students);
  const credentials = rowsOrEmpty(common.credentials);
  const credentialByLogin = new Map(credentials.map((c) => [String(c.login || '').toLowerCase(), c]));

  const credentialRows = students.map((s) => ({
    import_batch: s.import_batch || config.batch,
    record_book: s.record_book,
    login: loginOf(s),
    full_name: s.full_name,
    group_name: s.group_name,
    auth_email: emailForLogin(loginOf(s), config),
    auth_password: passwordFor(s, config),
    need_password_change: true,
    validation_status: 'pending',
    validation_errors: [],
  }));

  const missingCredentials = credentialRows.filter((row) => !credentialByLogin.has(row.login.toLowerCase()));
  await db.insert(config.auth_credentials_stage_table, missingCredentials, { onConflict: 'login', merge: true });

  const freshCredentials = await db.list(config.auth_credentials_stage_table);
  let created = 0;
  let errors = 0;
  for (const cred of freshCredentials) {
    if (cred.created_in_auth && cred.auth_user_id) continue;
    if (!cred.login || !cred.auth_email || !cred.auth_password) {
      await db.patchById(config.auth_credentials_stage_table, cred.id, { error_message: 'Missing login/auth_email/auth_password' });
      errors += 1;
      continue;
    }
    try {
      const result = await db.createAuthUser({
        email: cred.auth_email,
        password: cred.auth_password,
        email_confirm: true,
        user_metadata: {
          login: cred.login,
          record_book: cred.record_book,
          full_name: cred.full_name,
          group_name: cred.group_name,
          need_password_change: true,
          import_batch: cred.import_batch || config.batch,
        },
      });
      const userId = result?.user?.id || result?.id || result?.data?.user?.id;
      if (!userId) throw new Error('Admin API did not return user id');
      await db.patchById(config.auth_credentials_stage_table, cred.id, {
        auth_user_id: userId,
        created_in_auth: true,
        error_message: null,
      });
      created += 1;
    } catch (error) {
      await db.patchById(config.auth_credentials_stage_table, cred.id, {
        error_message: String(error.message || error).slice(0, 1000),
      });
      errors += 1;
    }
  }
  return { step: 'auth:apply', created, errors };
}

async function studentsSummary(ctx) {
  const { config } = ctx;
  const common = await loadCommon(ctx);
  const students = rowsOrEmpty(common.students);
  const credentials = rowsOrEmpty(common.credentials);
  const users = rowsOrEmpty(common.users);
  const groups = rowsOrEmpty(common.groups);
  const enrollments = rowsOrEmpty(common.enrollments);
  const userByLogin = new Map(users.map((u) => [String(u.login || '').toLowerCase(), u]));
  const credByLogin = new Map(credentials.map((c) => [String(c.login || '').toLowerCase(), c]));
  const groupByName = new Map(groups.map((g) => [g.name, g]));

  let publicUsersToCreate = 0;
  let publicUsersToUpdate = 0;
  let enrollmentsToCreate = 0;
  const blockedRows = [];

  for (const s of students) {
    const login = loginOf(s).toLowerCase();
    const user = userByLogin.get(login);
    const cred = credByLogin.get(login);
    const group = groupByName.get(s.group_name);
    if (!group) blockedRows.push({ login: s.login, reason: 'missing_group' });
    if (!cred?.created_in_auth || !cred?.auth_user_id) blockedRows.push({ login: s.login, reason: 'missing_created_auth_user' });

    if (!user && cred?.auth_user_id && group) publicUsersToCreate += 1;
    if (user && group) {
      const canUpdateGroupName = !isNonEmpty(user.group_name) || user.group_name === s.group_name;
      const canUpdatePrimaryGroup = !user.primary_group_id || user.primary_group_id === group.id;
      const roleOk = !isNonEmpty(user.role) || String(user.role).toLowerCase() === 'student';
      const needsUserUpdate =
        !isNonEmpty(user.name) ||
        !isNonEmpty(user.surname) ||
        !isNonEmpty(user.group_name) ||
        !user.primary_group_id ||
        !isNonEmpty(user.role) ||
        user.must_change_password !== true;
      if (!canUpdateGroupName) blockedRows.push({ login: s.login, reason: 'real_group_name_conflict' });
      if (!canUpdatePrimaryGroup) blockedRows.push({ login: s.login, reason: 'real_primary_group_id_conflict' });
      if (!roleOk) blockedRows.push({ login: s.login, reason: 'real_role_conflict' });
      if (needsUserUpdate) publicUsersToUpdate += 1;
    }

    const active = user ? enrollments.filter((e) => e.user_id === user.id && e.status === 'active' && !e.ended_at) : [];
    if (active.some((e) => e.group_id !== group?.id)) blockedRows.push({ login: s.login, reason: 'active_enrollment_other_group' });
    if (user && group && !active.some((e) => e.group_id === group.id)) enrollmentsToCreate += 1;
  }

  return {
    step: 'students',
    stageStudents: students.length,
    publicUsersToCreate,
    publicUsersToUpdate,
    enrollmentsToCreate,
    blocked: blockedRows.length,
    blockedDetails: blockedRows.slice(0, 20),
  };
}

async function applyStudents(ctx) {
  const { config, db } = ctx;
  const summary = await studentsSummary(ctx);
  printSummary(summary);
  if (summary.blocked > 0) throw new Error('Students apply blocked. Fix blocked rows first.');

  const common = await loadCommon(ctx);
  const students = rowsOrEmpty(common.students);
  const credentials = rowsOrEmpty(common.credentials);
  const users = rowsOrEmpty(common.users);
  const groups = rowsOrEmpty(common.groups);
  const enrollments = rowsOrEmpty(common.enrollments);
  const credByLogin = new Map(credentials.map((c) => [String(c.login || '').toLowerCase(), c]));
  const userByLogin = new Map(users.map((u) => [String(u.login || '').toLowerCase(), u]));
  const groupByName = new Map(groups.map((g) => [g.name, g]));
  let usersCreated = 0;
  let usersUpdated = 0;
  let enrollmentsCreated = 0;

  for (const s of students) {
    const login = loginOf(s);
    const cred = credByLogin.get(login.toLowerCase());
    const group = groupByName.get(s.group_name);
    if (!cred?.auth_user_id || !group) continue;

    let user = userByLogin.get(login.toLowerCase());
    if (!user) {
      const inserted = await db.insert('users', [{
        id: cred.auth_user_id,
        login,
        name: s.name || '',
        surname: s.surname || '',
        group_name: s.group_name,
        role: 'student',
        is_active: s.is_active !== false,
        primary_group_id: group.id,
        must_change_password: true,
      }]);
      user = inserted[0] || { id: cred.auth_user_id, login };
      userByLogin.set(login.toLowerCase(), user);
      usersCreated += 1;
    } else {
      const patch = {};
      if (!isNonEmpty(user.name)) patch.name = s.name || '';
      if (!isNonEmpty(user.surname)) patch.surname = s.surname || '';
      if (!isNonEmpty(user.group_name)) patch.group_name = s.group_name;
      if (!user.primary_group_id) patch.primary_group_id = group.id;
      if (!isNonEmpty(user.role)) patch.role = 'student';
      if (user.must_change_password !== true) patch.must_change_password = true;
      if (Object.keys(patch).length > 0) {
        await db.patchById('users', user.id, patch);
        usersUpdated += 1;
      }
    }

    const active = enrollments.filter((e) => e.user_id === user.id && e.status === 'active' && !e.ended_at);
    if (!active.some((e) => e.group_id === group.id)) {
      await db.insert('student_enrollments', [{
        user_id: user.id,
        group_id: group.id,
        started_at: `${config.admission_year}-09-01`,
        status: 'active',
        ended_at: null,
        transfer_reason: `${config.batch}_import`,
      }]);
      enrollmentsCreated += 1;
    }
  }
  return { step: 'students:apply', usersCreated, usersUpdated, enrollmentsCreated };
}

function curriculumCandidates(curriculum) {
  const realRows = curriculum
    .map((row) => ({
      ...row,
      normalized_subject_name: normalizeName(row.display_name || row.raw_subject_name),
      is_header: row.is_elective_module_header === true,
      include_catalog: row.include_in_subject_catalog !== false,
      include_offering: row.include_in_group_offerings_default !== false,
    }))
    .filter((row) => !row.is_header && row.include_catalog && row.normalized_subject_name);

  const subjects = uniqueBy(realRows.map((row) => ({
    normalized_name: row.normalized_subject_name,
    canonical_name: row.display_name || row.raw_subject_name,
  })), (row) => row.normalized_name);

  const aliases = uniqueBy(realRows.flatMap((row) => [row.raw_subject_name, row.display_name]
    .filter(isNonEmpty)
    .map((alias) => ({
      normalized_subject_name: row.normalized_subject_name,
      alias,
      normalized_alias: normalizeName(alias),
    }))), (row) => row.normalized_alias);

  const curriculumSubjects = uniqueBy(realRows.map((row) => ({
    normalized_subject_name: row.normalized_subject_name,
    raw_subject_name: row.raw_subject_name,
    display_name: row.display_name || row.raw_subject_name,
    semester_number: row.semester_number,
    hours_total: row.hours_total,
    credits: row.credits_total,
    subject_index: row.subject_index,
    block_name: row.block_name,
    control_form: row.control_form,
    department: row.department,
    subject_type: row.subject_type,
    subject_kind: row.subject_kind,
    is_elective: row.is_elective === true,
    elective_module_code: row.elective_module_code,
  })), (row) => [
    row.normalized_subject_name,
    row.raw_subject_name || '',
    row.display_name || '',
    row.semester_number ?? '',
    row.hours_total ?? '',
    row.credits ?? '',
  ].join('|'));

  const offerings = uniqueBy(realRows
    .filter((row) => row.include_offering)
    .map((row) => ({
      group_name: row.group_name,
      normalized_subject_name: row.normalized_subject_name,
      raw_subject_name: row.raw_subject_name,
      display_name: row.display_name || row.raw_subject_name,
      semester_number: row.semester_number,
      hours_total: row.hours_total,
      credits: row.credits_total,
    })), (row) => [row.group_name, row.semester_number, row.normalized_subject_name, row.display_name].join('|'));

  return { realRows, subjects, aliases, curriculumSubjects, offerings };
}

async function curriculumSummary(ctx) {
  const common = await loadCommon(ctx);
  const curriculum = rowsOrEmpty(common.curriculum);
  const groups = rowsOrEmpty(common.groups);
  const groupTerms = rowsOrEmpty(common.groupTerms);
  const existingSubjects = await ctx.db.list('subject_catalog');
  const existingAliases = await ctx.db.list('subject_aliases');
  const existingCurriculumSubjects = await ctx.db.list('curriculum_subjects');
  const existingOfferings = await ctx.db.list('subject_offerings');
  const candidates = curriculumCandidates(curriculum);
  const subjectByNorm = new Map(existingSubjects.map((s) => [s.normalized_name, s]));
  const aliasByNorm = new Map(existingAliases.map((a) => [a.normalized_alias, a]));
  const groupByName = new Map(groups.map((g) => [g.name, g]));
  const blockedRows = [];

  for (const offering of candidates.offerings) {
    const group = groupByName.get(offering.group_name);
    if (!group) blockedRows.push({ reason: 'missing_group', group_name: offering.group_name, display_name: offering.display_name });
    const term = group ? groupTerms.find((gt) => gt.group_id === group.id && Number(gt.semester_number) === Number(offering.semester_number)) : null;
    if (!term) blockedRows.push({ reason: 'missing_group_term_semester', group_name: offering.group_name, semester_number: offering.semester_number });
  }

  return {
    step: 'curriculum',
    stageCurriculum: curriculum.length,
    subjectCatalogCandidates: candidates.subjects.length,
    subjectCatalogToCreate: candidates.subjects.filter((s) => !subjectByNorm.has(s.normalized_name)).length,
    aliasesCandidates: candidates.aliases.length,
    aliasesToCreate: candidates.aliases.filter((a) => !aliasByNorm.has(a.normalized_alias)).length,
    curriculumSubjectsCandidates: candidates.curriculumSubjects.length,
    subjectOfferingsCandidates: candidates.offerings.length,
    existingCurriculumSubjects: existingCurriculumSubjects.length,
    existingSubjectOfferings: existingOfferings.length,
    electiveModuleHeadersSkipped: curriculum.filter((row) => row.is_elective_module_header === true).length,
    electiveOptionsCurriculumOnly: curriculum.filter((row) => row.is_elective_option === true && row.include_in_group_offerings_default === false).length,
    blocked: blockedRows.length,
    blockedDetails: blockedRows.slice(0, 20),
  };
}

async function applyCurriculum(ctx) {
  const { db } = ctx;
  const summary = await curriculumSummary(ctx);
  printSummary(summary);
  if (summary.blocked > 0) throw new Error('Curriculum apply blocked. Fix blocked rows first.');

  const common = await loadCommon(ctx);
  const groups = rowsOrEmpty(common.groups);
  const groupTerms = rowsOrEmpty(common.groupTerms);
  const candidates = curriculumCandidates(rowsOrEmpty(common.curriculum));

  await db.insert('subject_catalog', candidates.subjects, { onConflict: 'normalized_name', ignore: true });
  const subjects = await db.list('subject_catalog');
  const subjectByNorm = new Map(subjects.map((s) => [s.normalized_name, s]));

  const aliasRows = candidates.aliases
    .map((a) => ({
      subject_id: subjectByNorm.get(a.normalized_subject_name)?.id,
      alias: a.alias,
      normalized_alias: a.normalized_alias,
      source: ctx.config.batch,
    }))
    .filter((row) => row.subject_id);
  await db.insert('subject_aliases', aliasRows, { onConflict: 'normalized_alias', ignore: true });

  const existingCurriculum = await db.list('curriculum_subjects');
  const existingCurriculumKeys = new Set(existingCurriculum.map((row) => [
    row.subject_id,
    row.raw_subject_name || '',
    row.display_name || '',
    row.semester_number ?? '',
    row.hours_total ?? '',
    row.credits ?? '',
  ].join('|')));
  const curriculumRows = candidates.curriculumSubjects
    .map((row) => ({
      subject_id: subjectByNorm.get(row.normalized_subject_name)?.id,
      raw_subject_name: row.raw_subject_name,
      display_name: row.display_name,
      semester_number: row.semester_number,
      hours_total: row.hours_total,
      credits: row.credits,
      subject_index: row.subject_index,
      block_name: row.block_name,
      control_form: row.control_form,
      department: row.department,
      subject_type: row.subject_type,
      subject_kind: row.subject_kind,
      is_elective: row.is_elective,
      elective_module_code: row.elective_module_code,
    }))
    .filter((row) => row.subject_id)
    .filter((row) => !existingCurriculumKeys.has([
      row.subject_id,
      row.raw_subject_name || '',
      row.display_name || '',
      row.semester_number ?? '',
      row.hours_total ?? '',
      row.credits ?? '',
    ].join('|')));
  await db.insert('curriculum_subjects', curriculumRows);

  const freshCurriculum = await db.list('curriculum_subjects');
  const curriculumKey = (row) => [
    row.subject_id,
    row.raw_subject_name || '',
    row.display_name || '',
    row.semester_number ?? '',
    row.hours_total ?? '',
    row.credits ?? '',
  ].join('|');
  const curriculumByKey = new Map(freshCurriculum.map((row) => [curriculumKey(row), row]));
  const groupByName = new Map(groups.map((g) => [g.name, g]));
  const existingOfferings = await db.list('subject_offerings');
  const offeringKeys = new Set(existingOfferings.map((row) => [row.group_id, row.curriculum_subject_id, row.academic_year_id, row.academic_term_id].join('|')));
  const offeringRows = [];
  for (const offering of candidates.offerings) {
    const subject = subjectByNorm.get(offering.normalized_subject_name);
    const group = groupByName.get(offering.group_name);
    const term = groupTerms.find((gt) => gt.group_id === group?.id && Number(gt.semester_number) === Number(offering.semester_number));
    const cs = curriculumByKey.get([
      subject?.id,
      offering.raw_subject_name || '',
      offering.display_name || '',
      offering.semester_number ?? '',
      offering.hours_total ?? '',
      offering.credits ?? '',
    ].join('|'));
    if (!subject || !group || !term || !cs) continue;
    const key = [group.id, cs.id, term.academic_year_id, term.academic_term_id].join('|');
    if (offeringKeys.has(key)) continue;
    offeringRows.push({
      subject_id: subject.id,
      curriculum_subject_id: cs.id,
      group_id: group.id,
      academic_year_id: term.academic_year_id,
      academic_term_id: term.academic_term_id,
      semester_number: offering.semester_number,
      display_name: offering.display_name,
      status: 'active',
    });
  }
  await db.insert('subject_offerings', offeringRows, { ignore: true });
  return { step: 'curriculum:apply', subjectsInserted: summary.subjectCatalogToCreate, aliasesInserted: summary.aliasesToCreate, curriculumRowsInserted: curriculumRows.length, offeringsInserted: offeringRows.length };
}

async function teamsSummary(ctx) {
  const { config } = ctx;
  const [offerings, groups, teams, chats, enrollments, teamMembers, chatMembers] = await Promise.all([
    ctx.db.list('subject_offerings'),
    ctx.db.list('groups'),
    ctx.db.list('teams'),
    ctx.db.list('chats'),
    ctx.db.list('student_enrollments'),
    ctx.db.list('team_members'),
    ctx.db.list('chat_members'),
  ]);
  const groupById = new Map(groups.map((g) => [g.id, g]));
  const currentOfferings = offerings.filter((so) => config.groups.includes(groupById.get(so.group_id)?.name) && Number(so.semester_number) === Number(config.current_semester_number));
  const teamsByOffering = new Map(teams.filter((t) => t.subject_offering_id).map((t) => [t.subject_offering_id, t]));
  const teamCandidates = currentOfferings.filter((so) => !teamsByOffering.has(so.id));
  const activeCountByGroup = groupCount(enrollments.filter((e) => e.status === 'active' && !e.ended_at), (e) => e.group_id);
  const teamMembersToCreate = teamCandidates.reduce((sum, so) => sum + (activeCountByGroup.get(so.group_id) || 0), 0);
  const duplicateTeams = rowsWithDuplicates(teams.filter((t) => t.subject_offering_id), (t) => t.subject_offering_id);
  const duplicateChats = rowsWithDuplicates(chats.filter((c) => c.team_id && c.type === 'team_main'), (c) => c.team_id);
  const duplicateTeamMembers = rowsWithDuplicates(teamMembers, (tm) => `${tm.team_id}|${tm.user_id}`);
  const duplicateChatMembers = rowsWithDuplicates(chatMembers, (cm) => `${cm.chat_id}|${cm.user_id}`);
  const blockedRows = currentOfferings.filter((so) => !so.group_id || !so.subject_id || !so.id || (activeCountByGroup.get(so.group_id) || 0) === 0);
  return {
    step: 'teams',
    currentSemesterOfferings: currentOfferings.length,
    teamsToCreate: teamCandidates.length,
    chatsExpectedFromTrigger: teamCandidates.length,
    teamMembersToCreate,
    chatMembersExpectedFromTrigger: teamMembersToCreate,
    duplicateTeams: duplicateTeams.length,
    duplicateChats: duplicateChats.length,
    duplicateTeamMembers: duplicateTeamMembers.length,
    duplicateChatMembers: duplicateChatMembers.length,
    blocked: blockedRows.length,
    blockedDetails: blockedRows.slice(0, 20),
  };
}

async function applyTeams(ctx) {
  const { config, db } = ctx;
  const summary = await teamsSummary(ctx);
  printSummary(summary);
  if (summary.blocked > 0) throw new Error('Teams apply blocked. Fix blocked rows first.');

  const [offerings, groups, teams, enrollments] = await Promise.all([
    db.list('subject_offerings'),
    db.list('groups'),
    db.list('teams'),
    db.list('student_enrollments'),
  ]);
  const groupById = new Map(groups.map((g) => [g.id, g]));
  const teamsByOffering = new Map(teams.filter((t) => t.subject_offering_id).map((t) => [t.subject_offering_id, t]));
  const currentOfferings = offerings.filter((so) => config.groups.includes(groupById.get(so.group_id)?.name) && Number(so.semester_number) === Number(config.current_semester_number));
  const teamRows = currentOfferings
    .filter((so) => !teamsByOffering.has(so.id))
    .map((so) => ({
      name: so.display_name,
      description: '',
      teacher: '',
      icon: '',
      group_name: null,
      group_id: so.group_id,
      subject_id: so.subject_id,
      subject_offering_id: so.id,
      academic_year_id: so.academic_year_id,
      academic_term_id: so.academic_term_id,
      semester_number: so.semester_number,
    }));
  await db.insert('teams', teamRows, { ignore: true });

  const freshTeams = await db.list('teams');
  const teamByOffering = new Map(freshTeams.filter((t) => t.subject_offering_id).map((t) => [t.subject_offering_id, t]));
  const existingMembers = await db.list('team_members');
  const memberKeys = new Set(existingMembers.map((tm) => `${tm.team_id}|${tm.user_id}`));
  const memberRows = [];
  for (const so of currentOfferings) {
    const team = teamByOffering.get(so.id);
    if (!team) continue;
    for (const enrollment of enrollments.filter((e) => e.group_id === so.group_id && e.status === 'active' && !e.ended_at)) {
      const key = `${team.id}|${enrollment.user_id}`;
      if (!memberKeys.has(key)) memberRows.push({ team_id: team.id, user_id: enrollment.user_id, role: 'member' });
    }
  }
  await db.insert('team_members', memberRows, { ignore: true });

  for (const so of currentOfferings) {
    const team = teamByOffering.get(so.id);
    const group = groupById.get(so.group_id);
    if (team && group && !isNonEmpty(team.group_name)) {
      await db.patchById('teams', team.id, { group_name: group.name });
    }
  }
  return { step: 'teams:apply', teamsInserted: teamRows.length, teamMembersInserted: memberRows.length };
}

async function postcheckSummary(ctx) {
  const [users, enrollments, offerings, teams, chats, teamMembers, chatMembers] = await Promise.all([
    ctx.db.list('users'),
    ctx.db.list('student_enrollments'),
    ctx.db.list('subject_offerings'),
    ctx.db.list('teams'),
    ctx.db.list('chats'),
    ctx.db.list('team_members'),
    ctx.db.list('chat_members'),
  ]);
  const teamByOffering = new Map(teams.filter((t) => t.subject_offering_id).map((t) => [t.subject_offering_id, t]));
  const currentTeams = offerings
    .filter((so) => Number(so.semester_number) === Number(ctx.config.current_semester_number))
    .map((so) => teamByOffering.get(so.id))
    .filter(Boolean);
  return {
    step: 'postcheck',
    users: users.length,
    activeEnrollments: enrollments.filter((e) => e.status === 'active' && !e.ended_at).length,
    subjectOfferings: offerings.length,
    currentSemesterTeams: currentTeams.length,
    teamMainChats: chats.filter((c) => currentTeams.some((t) => t.id === c.team_id) && c.type === 'team_main').length,
    teamMembers: teamMembers.length,
    chatMembers: chatMembers.length,
    duplicateTeamMembers: rowsWithDuplicates(teamMembers, (tm) => `${tm.team_id}|${tm.user_id}`).length,
    duplicateChatMembers: rowsWithDuplicates(chatMembers, (cm) => `${cm.chat_id}|${cm.user_id}`).length,
    blocked: 0,
  };
}

function printSummary(summary) {
  console.log(JSON.stringify(summary, null, 2));
}

async function runStep(ctx, step, apply) {
  if (step === 'preflight') return preflightSummary(ctx);
  if (step === 'auth') return apply ? applyAuth(ctx) : authSummary(ctx);
  if (step === 'students') return apply ? applyStudents(ctx) : studentsSummary(ctx);
  if (step === 'curriculum') return apply ? applyCurriculum(ctx) : curriculumSummary(ctx);
  if (step === 'teams') return apply ? applyTeams(ctx) : teamsSummary(ctx);
  if (step === 'postcheck') return postcheckSummary(ctx);
  throw new Error(`Unsupported step: ${step}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  loadDotEnvLocal();
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY in environment or .env.local');
  }

  const config = readJson(args.config);
  const db = new SupabaseRest(supabaseUrl, serviceRoleKey);
  const ctx = makeContext(config, db);

  console.log(`[academic-import] batch=${config.batch} mode=${args.apply ? 'apply' : 'dry-run'} step=${args.step}`);
  if (!args.apply) console.log('[academic-import] dry-run only; no production writes will be made.');

  const steps = args.step === 'all'
    ? ['preflight', 'auth', 'students', 'curriculum', 'teams', 'postcheck']
    : [args.step];

  for (const step of steps) {
    ctx.cache = {};
    const summary = await runStep(ctx, step, args.apply);
    printSummary(summary);
    if (!args.apply && summary.blocked > 0) {
      console.log(`[academic-import] ${step} has blocked rows. Apply would be refused.`);
    }
  }
}

main().catch((error) => {
  console.error(`[academic-import] ERROR: ${error.message || error}`);
  if (error.body) console.error(JSON.stringify(error.body, null, 2));
  process.exitCode = 1;
});
