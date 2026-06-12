// Env vars are always strings; Sequelize's `logging` wants a function or false.
// Treat "true" as console.log, anything else as disabled.
const logging = (value) => (value === "true" ? console.log : false);

/** @type {import('sequelize').Options} */
module.exports = {
  development: {
    username: process.env.DEV_DB_USERNAME,
    password: process.env.DEV_DB_PASSWORD,
    database: process.env.DEV_DB_NAME,
    host: process.env.DEV_DB_HOSTNAME,
    dialect: process.env.DEV_DB_DIALECT,
    logging: logging(process.env.DEV_DB_LOGGING),
  },
  test: {
    username: process.env.TEST_DB_USERNAME,
    password: process.env.TEST_DB_PASSWORD,
    database: process.env.TEST_DB_NAME,
    host: process.env.TEST_DB_HOSTNAME,
    dialect: process.env.TEST_DB_DIALECT,
    logging: logging(process.env.TEST_DB_LOGGING),
  },
  production: {
    username: process.env.PROD_DB_USERNAME,
    password: process.env.PROD_DB_PASSWORD,
    database: process.env.PROD_DB_NAME,
    host: process.env.PROD_DB_HOSTNAME,
    dialect: process.env.PROD_DB_DIALECT,
    logging: logging(process.env.PROD_DB_LOGGING),
    // RDS PostgreSQL 16 enforces TLS (rds.force_ssl=1), so the client must
    // connect over SSL or the server rejects it with a pg_hba.conf error.
    // rejectUnauthorized is false because we don't bundle the AWS RDS CA — the
    // link is still encrypted; full chain verification is a hardening follow-up.
    dialectOptions:
      process.env.PROD_DB_SSL === "true"
        ? { ssl: { require: true, rejectUnauthorized: false } }
        : undefined,
  },
};
