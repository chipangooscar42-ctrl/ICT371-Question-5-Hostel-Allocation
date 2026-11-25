
/* ============================================================
   ICT371 - QUESTION 5
   HOSTEL ROOM ALLOCATION

   STUDENT NAME: Enter your full name
   STUDENT NUMBER: Enter your student number
   COURSE CODE: ICT371
   ASSIGNMENT: Question 5 - Hostel Room Allocation
   ============================================================ */


-- ============================================================
-- 1. CLEAN UP PREVIOUS QUESTION 5 OBJECTS
-- ============================================================

DROP VIEW IF EXISTS v_room_occupancy CASCADE;

DROP PROCEDURE IF EXISTS pr_allocate_room(INTEGER, INTEGER, DATE);
DROP PROCEDURE IF EXISTS pr_refresh_occupancy();

DROP FUNCTION IF EXISTS fn_free_beds(INTEGER);
DROP FUNCTION IF EXISTS fn_check_room_allocation();

DROP TABLE IF EXISTS occupancy_snapshot CASCADE;
DROP TABLE IF EXISTS allocations CASCADE;
DROP TABLE IF EXISTS rooms CASCADE;
DROP TABLE IF EXISTS students CASCADE;


-- ============================================================
-- 2. CREATE STUDENTS TABLE
-- ============================================================

CREATE TABLE students (
    student_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL
);


-- ============================================================
-- 3. CREATE ROOMS TABLE
-- ============================================================

CREATE TABLE rooms (
    room_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);


-- ============================================================
-- 4. CREATE ALLOCATIONS TABLE
-- ============================================================

CREATE TABLE allocations (
    allocation_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL,

    CONSTRAINT chk_allocation_status
        CHECK (status IN ('ACTIVE', 'ENDED')),

    CONSTRAINT chk_allocation_dates
        CHECK (
            (status = 'ACTIVE' AND released_on IS NULL)
            OR
            (status = 'ENDED' AND released_on IS NOT NULL
             AND released_on >= allocated_on)
        )
);


-- ============================================================
-- 5. CREATE OCCUPANCY SNAPSHOT TABLE
-- One record per date and room.
-- ============================================================

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds INTEGER NOT NULL CHECK (free_beds >= 0),

    PRIMARY KEY (snapshot_date, room_id)
);


-- ============================================================
-- 6. INSERT THREE ROOMS
-- Room 1: Full
-- Room 2: Partly occupied
-- Room 3: Empty
-- ============================================================

INSERT INTO rooms (room_number, capacity)
VALUES
    ('ROOM-101', 2),
    ('ROOM-102', 3),
    ('ROOM-103', 2);


-- ============================================================
-- 7. INSERT FIVE STUDENTS
-- ============================================================

INSERT INTO students (student_number, full_name)
VALUES
    ('STU001', 'John Banda'),
    ('STU002', 'Mary Phiri'),
    ('STU003', 'Peter Zulu'),
    ('STU004', 'Grace Tembo'),
    ('STU005', 'David Chanda');


-- ============================================================
-- 8. CREATE FUNCTION
-- fn_free_beds(p_room_id)
-- Returns room capacity minus ACTIVE allocations.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;

    SELECT COUNT(*)::INTEGER
    INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;


-- ============================================================
-- 9. CREATE TRIGGER FUNCTION
-- Enforces room capacity and one ACTIVE allocation per student.
-- Excludes the current row when checking an UPDATE.
-- ============================================================

CREATE OR REPLACE FUNCTION fn_check_room_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN

        -- Check whether the student already has another
        -- ACTIVE allocation.

        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND (
                    TG_OP = 'INSERT'
                    OR a.allocation_id <> NEW.allocation_id
                  )
        ) THEN
            RAISE EXCEPTION
                'This student already has an ACTIVE room allocation';
        END IF;


        -- Get the room capacity.

        SELECT capacity
        INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room ID: %', NEW.room_id;
        END IF;


        -- Count other ACTIVE allocations in the room.
        -- On UPDATE, exclude the allocation being changed.

        SELECT COUNT(*)::INTEGER
        INTO v_occupied
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (
                TG_OP = 'INSERT'
                OR a.allocation_id <> NEW.allocation_id
              );


        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION
                'Room % is full. No additional bed is available',
                NEW.room_id;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;


-- ============================================================
-- 10. CREATE BEFORE INSERT OR UPDATE TRIGGER
-- ============================================================

CREATE TRIGGER trg_check_room_allocation
BEFORE INSERT OR UPDATE
ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_room_allocation();


-- ============================================================
-- 11. INSERT SAMPLE ALLOCATIONS
-- The trigger is already installed.
--
-- Room 101: two ACTIVE students (FULL)
-- Room 102: one ACTIVE student (PARTLY OCCUPIED)
-- Room 103: zero ACTIVE students (EMPTY)
--
-- ENDED allocations are retained as history.
-- ============================================================

INSERT INTO allocations (
    student_id,
    room_id,
    allocated_on,
    released_on,
    status
)
VALUES
    (1, 1, CURRENT_DATE - 30, NULL, 'ACTIVE'),
    (2, 1, CURRENT_DATE - 25, NULL, 'ACTIVE'),
    (3, 2, CURRENT_DATE - 20, NULL, 'ACTIVE'),
    (4, 2, CURRENT_DATE - 60, CURRENT_DATE - 10, 'ENDED'),
    (5, 1, CURRENT_DATE - 90, CURRENT_DATE - 30, 'ENDED');


-- ============================================================
-- 12. CREATE PROCEDURE
-- pr_allocate_room
-- Validates student, room and availability.
-- Creates an ACTIVE allocation.
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate student.

    IF p_student_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM students
        WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION 'Unknown student ID: %', p_student_id;
    END IF;


    -- Validate room.

    IF p_room_id IS NULL OR NOT EXISTS (
        SELECT 1
        FROM rooms
        WHERE room_id = p_room_id
    ) THEN
        RAISE EXCEPTION 'Unknown room ID: %', p_room_id;
    END IF;


    -- Validate allocation date.

    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;


    -- Ensure student has no ACTIVE allocation.

    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
            'Student % already has an ACTIVE allocation',
            p_student_id;
    END IF;


    -- Check room availability.

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION
            'Room % is full. No free bed available',
            p_room_id;
    END IF;


    -- Create the ACTIVE allocation.
    -- The trigger also checks the rules.

    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

    RAISE NOTICE 'Room allocated successfully';

END;
$$;


-- ============================================================
-- 13. TEST THE ALLOCATION PROCEDURE
-- Student 4 previously had an ENDED allocation.
-- Student 4 can therefore receive a new ACTIVE allocation.
-- Room 102 still has available capacity.
-- ============================================================

CALL pr_allocate_room(
    4,
    2,
    CURRENT_DATE
);


-- ============================================================
-- 14. CREATE VIEW
-- Shows every room, including empty rooms.
-- ============================================================

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,

    COUNT(a.allocation_id)
        FILTER (WHERE a.status = 'ACTIVE')::INTEGER
        AS occupied_beds,

    r.capacity -
    COUNT(a.allocation_id)
        FILTER (WHERE a.status = 'ACTIVE')::INTEGER
        AS free_beds

FROM rooms r
LEFT JOIN allocations a
    ON r.room_id = a.room_id

GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;


-- ============================================================
-- 15. CREATE PARTIAL INDEX
-- Supports searches for ACTIVE allocations by room_id.
-- ============================================================

CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';


-- ============================================================
-- 16. CREATE OCCUPANCY REFRESH PROCEDURE
-- Stores CURRENT_DATE occupancy for every room.
-- Replaces existing values when run again.
-- ============================================================

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )
    SELECT
        CURRENT_DATE,
        r.room_id,

        COUNT(a.allocation_id)
            FILTER (WHERE a.status = 'ACTIVE')::INTEGER,

        r.capacity -
        COUNT(a.allocation_id)
            FILTER (WHERE a.status = 'ACTIVE')::INTEGER

    FROM rooms r
    LEFT JOIN allocations a
        ON r.room_id = a.room_id

    GROUP BY
        r.room_id,
        r.capacity

    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;

    RAISE NOTICE
        'Occupancy snapshot refreshed for %',
        CURRENT_DATE;

END;
$$;


-- ============================================================
-- 17. TEST THE FREE BEDS FUNCTION
-- ============================================================

SELECT
    room_id,
    room_number,
    capacity,
    fn_free_beds(room_id) AS free_beds
FROM rooms
ORDER BY room_id;


-- ============================================================
-- 18. DISPLAY ROOM OCCUPANCY VIEW
-- ============================================================

SELECT *
FROM v_room_occupancy
ORDER BY room_id;


-- ============================================================
-- 19. DISPLAY ALL ALLOCATIONS
-- ============================================================

SELECT
    a.allocation_id,
    s.student_number,
    s.full_name,
    r.room_number,
    a.allocated_on,
    a.released_on,
    a.status
FROM allocations a
JOIN students s
    ON a.student_id = s.student_id
JOIN rooms r
    ON a.room_id = r.room_id
ORDER BY a.allocation_id;


-- ============================================================
-- 20. REFRESH AND DISPLAY OCCUPANCY SNAPSHOT
-- ============================================================

CALL pr_refresh_occupancy();

SELECT *
FROM occupancy_snapshot
ORDER BY snapshot_date, room_id;


-- ============================================================
-- 21. EXPLAIN QUERY FOR THE PARTIAL INDEX
-- ============================================================

EXPLAIN
SELECT *
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';


-- ============================================================
-- 22. SCHEDULE DAILY JOB AT 23:55
-- Requires pg_cron to be installed and configured.
-- ============================================================

DO $$
DECLARE
    v_job RECORD;
BEGIN

    EXECUTE 'CREATE EXTENSION IF NOT EXISTS pg_cron';

    -- Remove an older job with the same name.

    FOR v_job IN
        EXECUTE
        'SELECT jobid
         FROM cron.job
         WHERE jobname = $1'
        USING 'ict371_hostel_occupancy_daily'
    LOOP
        EXECUTE 'SELECT cron.unschedule($1)'
        USING v_job.jobid;
    END LOOP;


    -- Schedule the daily occupancy refresh at 23:55.

    EXECUTE
        'SELECT cron.schedule($1, $2, $3)'
    USING
        'ict371_hostel_occupancy_daily',
        '55 23 * * *',
        'CALL pr_refresh_occupancy();';

    RAISE NOTICE
        'Daily occupancy job scheduled for 23:55';

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE
            'pg_cron could not be configured: %. Other SQL objects were created.',
            SQLERRM;
END;
$$;


-- ============================================================
-- 23. FINAL TABLE COUNTS
-- ============================================================

SELECT COUNT(*) AS total_students
FROM students;

SELECT COUNT(*) AS total_rooms
FROM rooms;

SELECT COUNT(*) AS total_allocations
FROM allocations;

SELECT COUNT(*) AS total_occupancy_snapshots
FROM occupancy_snapshot;


-- ============================================================
-- END OF QUESTION 5
-- ============================================================
