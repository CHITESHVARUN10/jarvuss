//! PostgreSQL provisioning SQL, quoting, validation and failure redaction.
//! Process execution and psql discovery remain native.

use rand::Rng;

#[uniffi::export]
pub fn create_role_sql(user: String, password: String) -> String {
    format!(
        "SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', {}, {})\nWHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = {})\n\\gexec\n",
        quote_literal(user.clone()),
        quote_literal(password),
        quote_literal(user)
    )
}

#[uniffi::export]
pub fn create_database_sql(database: String, user: String) -> String {
    format!(
        "CREATE DATABASE {} OWNER {};",
        quote_identifier(database),
        quote_identifier(user)
    )
}

#[uniffi::export]
pub fn database_exists_query(database: String) -> String {
    format!(
        "SELECT 1 FROM pg_catalog.pg_database WHERE datname = {};",
        quote_literal(database)
    )
}

#[uniffi::export]
pub fn role_exists_query(user: String) -> String {
    format!(
        "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = {};",
        quote_literal(user)
    )
}

#[uniffi::export]
pub fn quote_identifier(identifier: String) -> String {
    format!("\"{}\"", identifier.replace('"', "\"\""))
}

#[uniffi::export]
pub fn quote_literal(value: String) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

#[uniffi::export]
pub fn generated_password() -> String {
    // Ambiguous characters excluded so the wizard's editable field stays readable.
    const ALPHABET: &[u8] = b"abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::rng();
    (0..24)
        .map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char)
        .collect()
}

#[uniffi::export]
pub fn validate_provision_plan(
    database: String,
    user: String,
    password: String,
    port: String,
    administrator: String,
    administrator_password: String,
) -> bool {
    let valid_name = |value: &str| {
        !value.is_empty() && value.as_bytes().len() <= 63 && !value.contains('\0')
    };
    valid_name(&database)
        && valid_name(&user)
        && !password.contains('\0')
        && !administrator.is_empty()
        && !administrator.contains('\0')
        && !administrator_password.contains('\0')
        && port
            .parse::<u16>()
            .map(|value| (1..=65535).contains(&value))
            .unwrap_or(false)
}

#[uniffi::export]
pub fn connection_failure(
    detail: String,
    user: String,
    password: String,
    administrator_password: String,
    verify_login: bool,
) -> String {
    let lower = detail.to_lowercase();
    let auth_failure = lower.contains("no password supplied")
        || lower.contains("password authentication failed");
    if !verify_login && auth_failure {
        return "PostgreSQL requires the existing server administrator's credentials. Enter the PostgreSQL administrator name and password in Setup. The Jarvis password field belongs to the application account, not the administrator.".to_string();
    }
    if verify_login && auth_failure {
        return format!(
            "The existing Jarvis role '{user}' rejected this password. Enter its current password; setup preserves existing role passwords."
        );
    }
    let mut redacted = detail;
    for secret in [password, administrator_password] {
        if !secret.is_empty() {
            redacted = redacted.replace(&secret, "[redacted]");
        }
    }
    if redacted.is_empty() {
        "PostgreSQL command failed.".to_string()
    } else {
        redacted
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quoting_and_sql_shapes() {
        assert_eq!(quote_identifier("a\"b".into()), "\"a\"\"b\"");
        assert_eq!(quote_literal("it's".into()), "'it''s'");
        assert_eq!(
            create_database_sql("jarvis".into(), "jarvis_role".into()),
            "CREATE DATABASE \"jarvis\" OWNER \"jarvis_role\";"
        );
        assert!(create_role_sql("role".into(), "pw".into()).ends_with("\\gexec\n"));
        assert_eq!(generated_password().len(), 24);
    }

    #[test]
    fn validation_and_redaction() {
        assert!(validate_provision_plan(
            "db".into(),
            "user".into(),
            "pw".into(),
            "5432".into(),
            "admin".into(),
            String::new()
        ));
        assert!(!validate_provision_plan(
            "db".into(),
            "user".into(),
            "pw".into(),
            "70000".into(),
            "admin".into(),
            String::new()
        ));
        assert!(!validate_provision_plan(
            "db".into(),
            "user".into(),
            "pw\0".into(),
            "5432".into(),
            "admin".into(),
            String::new()
        ));
        assert!(connection_failure(
            "password authentication failed".into(),
            "user".into(),
            "secret".into(),
            String::new(),
            false
        )
        .contains("administrator"));
        assert_eq!(
            connection_failure(
                "failed for secret".into(),
                "user".into(),
                "secret".into(),
                String::new(),
                true
            ),
            "failed for [redacted]"
        );
    }
}
