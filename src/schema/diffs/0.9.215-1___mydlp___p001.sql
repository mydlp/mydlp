ALTER TABLE AuthUser_AuthSecurityRole DROP FOREIGN KEY FKA97E96CA71D65EE9, DROP FOREIGN KEY FKA97E96CA3FF1C26A;
ALTER TABLE AuthUser ADD COLUMN emailHashCode INT(11) NOT NULL COMMENT '', ADD COLUMN role_id INT(11) NOT NULL COMMENT '';
UPDATE AuthUser SET emailHashCode=id;
UPDATE AuthUser SET role_id=(SELECT roles_id FROM AuthUser_AuthSecurityRole where AuthUser_id=id limit 1);
DROP TABLE AuthUser_AuthSecurityRole;
ALTER TABLE AuthUser ADD CONSTRAINT emailHashCode UNIQUE KEY(emailHashCode), ADD INDEX FK59398DB3A1D94A11 (role_id);
ALTER TABLE AuthUser ADD CONSTRAINT FK59398DB3A1D94A11 FOREIGN KEY FK59398DB3A1D94A11 (role_id) REFERENCES AuthSecurityRole (id) ON UPDATE NO ACTION ON DELETE NO ACTION;