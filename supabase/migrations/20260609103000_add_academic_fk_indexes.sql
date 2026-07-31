-- Add missing FK indexes for academic tables.
-- Safe structural migration: indexes only, no data changes.

create index if not exists group_term_semesters_academic_year_id_idx
on public.group_term_semesters(academic_year_id);

create index if not exists subject_aliases_subject_id_idx
on public.subject_aliases(subject_id);

create index if not exists subject_alias_review_queue_group_id_idx
on public.subject_alias_review_queue(group_id);

create index if not exists subject_alias_review_queue_academic_year_id_idx
on public.subject_alias_review_queue(academic_year_id);

create index if not exists subject_alias_review_queue_resolved_subject_id_idx
on public.subject_alias_review_queue(resolved_subject_id);

create index if not exists subject_alias_review_queue_resolved_by_idx
on public.subject_alias_review_queue(resolved_by);

create index if not exists subject_offerings_academic_year_id_idx
on public.subject_offerings(academic_year_id);

create index if not exists subject_offerings_curriculum_subject_id_idx
on public.subject_offerings(curriculum_subject_id);

create index if not exists student_enrollments_created_by_idx
on public.student_enrollments(created_by);

create index if not exists student_enrollments_transferred_from_enrollment_id_idx
on public.student_enrollments(transferred_from_enrollment_id);

create index if not exists offering_teachers_teacher_id_idx
on public.offering_teachers(teacher_id);
