comment on column public.teacher_difficulty_votes.score is
  'Ease of passing with this teacher: 1 = very hard, 5 = easy';

-- Preserve the meaning of votes cast with the former scale,
-- where 1 meant easy and 5 meant very hard.
update public.teacher_difficulty_votes
set score = 6 - score;
