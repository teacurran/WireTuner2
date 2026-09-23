-- SRV-003: accounts, identities, devices, teams and workspaces (docs/spec/security.adoc, Schema).
-- Plain SQL on purpose: the compose main-db-migrations job applies these files with the Flyway
-- Maven plugin alone, without the api classpath.

CREATE TABLE account (
    id           uuid        PRIMARY KEY,
    -- The Keycloak subject; every sign-in method ends in the same subject, so one row per person.
    subject      text        NOT NULL UNIQUE,
    email        text        NOT NULL DEFAULT '',
    display_name text        NOT NULL DEFAULT '',
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- One row per linked sign-in method (password, apple, sso:<idp alias>). Passkeys are not
-- identities: a passkey is registered on an account that is already signed in.
CREATE TABLE account_identity (
    account_id       uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    provider         text        NOT NULL,
    provider_subject text        NOT NULL,
    email            text        NOT NULL DEFAULT '',
    email_verified   boolean     NOT NULL DEFAULT false,
    -- Apple private relay addresses link but never match a workspace domain.
    is_relay         boolean     NOT NULL DEFAULT false,
    linked_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (provider, provider_subject)
);
CREATE INDEX account_identity_account_idx ON account_identity (account_id);

-- A Mac the account has signed in on, keyed by the client's stable per-install id (wt-device)
-- together with the account: the same Mac used by two people is two rows.
CREATE TABLE device (
    id           uuid        NOT NULL,
    account_id   uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    name         text        NOT NULL DEFAULT '',
    platform     text        NOT NULL DEFAULT '',
    -- The token's wt_auth_method the first time the device was seen: passkey, apple, password
    -- or sso:<idp alias>.
    auth_method  text        NOT NULL DEFAULT 'password',
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at   timestamptz,
    PRIMARY KEY (account_id, id)
);

CREATE TABLE team (
    id                    uuid        PRIMARY KEY,
    name                  text        NOT NULL,
    slug                  text        NOT NULL UNIQUE,
    owner_account_id      uuid        NOT NULL REFERENCES account (id),
    -- The document role a member holds on team documents without an explicit share.
    default_document_role text        NOT NULL DEFAULT 'editor'
        CHECK (default_document_role IN ('editor', 'commenter', 'viewer')),
    created_at            timestamptz NOT NULL DEFAULT now(),
    deleted_at            timestamptz
);

CREATE TABLE team_member (
    team_id    uuid        NOT NULL REFERENCES team (id) ON DELETE CASCADE,
    account_id uuid        NOT NULL REFERENCES account (id) ON DELETE CASCADE,
    role       text        NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'guest')),
    joined_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (team_id, account_id)
);
CREATE INDEX team_member_account_idx ON team_member (account_id);
-- Exactly one owner per team.
CREATE UNIQUE INDEX team_member_one_owner ON team_member (team_id) WHERE role = 'owner';

CREATE TABLE team_invite (
    id          uuid        PRIMARY KEY,
    team_id     uuid        NOT NULL REFERENCES team (id) ON DELETE CASCADE,
    email       text        NOT NULL,
    role        text        NOT NULL CHECK (role IN ('admin', 'member', 'guest')),
    -- sha256 of the invitation token, lower-case hex; the token itself is only in the mail.
    token_hash  text        NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    accepted_at timestamptz
);
CREATE INDEX team_invite_team_idx ON team_invite (team_id);

-- A team bound to a company workspace: SSO connection and the three switches.
CREATE TABLE workspace (
    team_id          uuid    PRIMARY KEY REFERENCES team (id) ON DELETE CASCADE,
    sso_idp_alias    text,
    require_sso      boolean NOT NULL DEFAULT false,
    auto_admit       boolean NOT NULL DEFAULT false,
    restrict_sharing boolean NOT NULL DEFAULT false
);

CREATE TABLE workspace_domain (
    team_id            uuid        NOT NULL REFERENCES workspace (team_id) ON DELETE CASCADE,
    domain             text        NOT NULL,
    verification_token text        NOT NULL,
    verified_at        timestamptz,
    PRIMARY KEY (team_id, domain)
);
-- A domain is verified by at most one team.
CREATE UNIQUE INDEX workspace_domain_verified_once ON workspace_domain (domain) WHERE verified_at IS NOT NULL;
