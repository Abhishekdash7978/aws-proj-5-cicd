-- Idempotent: safe to run on every pipeline execution.
CREATE TABLE IF NOT EXISTS messages (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  body       VARCHAR(255) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO messages (body)
SELECT 'Hello from RDS' FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM messages);
