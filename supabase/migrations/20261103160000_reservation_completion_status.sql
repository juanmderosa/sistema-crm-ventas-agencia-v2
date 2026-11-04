-- Commit the enum extension before a later migration uses the new value.
alter type public.reservation_status add value 'completed';
