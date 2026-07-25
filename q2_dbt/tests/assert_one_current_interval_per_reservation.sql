-- SCD-2 invariant: each reservation has exactly one current interval (is_current = true).
-- The test fails if it returns any rows — i.e. a reservation with zero or more than one current
-- interval, which would mean the LEAD-based interval build is broken.
select
    reservation_id,
    countif(is_current) as current_intervals
from {{ ref('stg_reservations') }}
group by reservation_id
having countif(is_current) <> 1
