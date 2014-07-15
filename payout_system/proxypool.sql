BEGIN;

-- shares table
CREATE TABLE IF NOT EXISTS shares (
    id         bigserial        PRIMARY KEY,
    address    varchar(34)      NOT NULL,
    difficulty double precision NOT NULL,
    nethash    double precision NOT NULL,
    logged     timestamp        NOT NULL DEFAULT NOW(),
    coin       smallint         NOT NULL DEFAULT 0
);

-- index on id
DROP INDEX IF EXISTS shares_idx;
CREATE INDEX shares_idx ON shares USING btree (id);

-- balances table
CREATE TABLE IF NOT EXISTS balances (
    address varchar(34)      PRIMARY KEY,
    balance double precision NOT NULL,
    updated timestamp        NOT NULL DEFAULT NOW()
);

-- index on address
DROP INDEX IF EXISTS balance_idx;
CREATE INDEX balance_idx ON balances USING hash (address);

CREATE TABLE IF NOT EXISTS transactions (
    id     bigserial        PRIMARY KEY,
    txid   char(64)         DEFAULT NULL,
    total  double precision NOT NULL,
    paidat timestamp        DEFAULT NULL
);

-- record who and when we paid
CREATE TABLE IF NOT EXISTS paylog (
    id      bigserial        PRIMARY KEY,
    tid     bigserial        REFERENCES transactions(id),
    address varchar(34)      NOT NULL,
    amount  double precision NOT NULL
);

DROP FUNCTION IF EXISTS new_tid(DOUBLE PRECISION, DOUBLE PRECISION);
CREATE OR REPLACE FUNCTION new_tid(wallet DOUBLE PRECISION, minpay DOUBLE PRECISION) RETURNS BIGINT AS
$$
DECLARE
    payable_debt DOUBLE PRECISION;
    next_tid     BIGINT;
    account      RECORD;
BEGIN
    -- Debt (balances) table must be hard locked off, we'll use it as a mutex
    LOCK TABLE balances IN ACCESS EXCLUSIVE MODE;

    SELECT INTO payable_debt COALESCE(SUM(floor(balance)), 0) FROM balances WHERE floor(balance) >= minpay;
    IF payable_debt > wallet OR payable_debt = 0 THEN
        RETURN null;
    END IF;

    -- Generate a new tid
    INSERT INTO transactions(total) VALUES (payable_debt) RETURNING id INTO next_tid;

    -- Generate individual payouts
    FOR account IN SELECT address as who,
                          floor(balance) as pay
                   FROM balances
                   WHERE floor(balance) >= minpay
                   LOOP

        INSERT INTO paylog(tid, address, amount) VALUES (next_tid, account.who, account.pay);
    END LOOP;

    -- Clean out the ones we just paid
    DELETE FROM balances WHERE floor(balance) >= minpay;

    RETURN next_tid;
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION IF EXISTS add_balance(VARCHAR, DOUBLE PRECISION);
-- upsert script
CREATE OR REPLACE FUNCTION add_balance(who VARCHAR, pay DOUBLE PRECISION) RETURNS VOID AS
$$
BEGIN
    LOOP
        -- first try to update the key
        UPDATE balances SET balance = balance + pay, updated = NOW() WHERE address = who;
        IF found THEN
            RETURN;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO balances(address, balance) VALUES (who, pay);
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

DROP TYPE IF EXISTS section_type CASCADE;
CREATE TYPE section_type AS (low BIGINT, high BIGINT);

DROP FUNCTION IF EXISTS pay_to_balances(DOUBLE PRECISION, DOUBLE PRECISION);
-- payout script, collects shares from the shares table and moves them to the payout table
CREATE OR REPLACE FUNCTION pay_to_balances(block_value DOUBLE PRECISION, wallet DOUBLE PRECISION) RETURNS section_type AS
$$
DECLARE
    debt    DOUBLE PRECISION;
    section section_type;
    payitem RECORD;
BEGIN
    -- Debt (balances) table must be hard locked off, we'll use it as a mutex
    LOCK TABLE balances IN ACCESS EXCLUSIVE MODE;

    -- Find out how much we owe
    SELECT INTO debt COALESCE(SUM(balance), 0) FROM balances;
    RAISE NOTICE 'Debt: %', debt;

    -- Find the section to pay
    SELECT INTO section COALESCE(MIN(id), 0) as low, COALESCE(MAX(id), 0) as high
    FROM
       (SELECT id,
               SUM(block_value * (difficulty / nethash))
        OVER (ORDER BY id DESC) as total
        FROM shares
        ORDER BY id DESC
       ) AS ss
    WHERE total < wallet - debt;

    IF NOT FOUND OR (section.low = 0 AND section.high = 0) THEN
        RAISE NOTICE 'Nothing to pay (or to pay with)';
        RETURN section;
    END IF;

    -- Aggregate the payouts
    FOR payitem IN SELECT address as who,
                          SUM(block_value * (difficulty / nethash)) as pay
                   FROM shares
                   WHERE id BETWEEN section.low and section.high
                   GROUP BY address
                   LOOP

        PERFORM add_balance(payitem.who, payitem.pay);
    END LOOP;

    -- Remove already paid shares
    DELETE FROM shares WHERE id BETWEEN section.low and section.high;
    RETURN section;
END;
$$ LANGUAGE plpgsql;

COMMIT;
