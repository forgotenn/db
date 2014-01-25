--delete old data--
DROP TABLE IF EXISTS patient      CASCADE;
DROP TABLE IF EXISTS employee     CASCADE;
DROP TABLE IF EXISTS disease      CASCADE;
DROP TABLE IF EXISTS department   CASCADE;
DROP TABLE IF EXISTS case_history CASCADE;
DROP TABLE IF EXISTS job          CASCADE;
DROP TABLE IF EXISTS employment   CASCADE;
DROP TYPE  IF EXISTS status       CASCADE;

-- creating database
BEGIN; 
CREATE TABLE patient (
       id               serial PRIMARY KEY,
       first_name       text   NOT NULL,
       last_name        text   NOT NULL,
       credentials      text   NOT NULL,
       phone            text   NULL
);

CREATE TABLE department (
       id               serial PRIMARY KEY,
       name             text   NOT NULL,
       description      text   NULL 
);

CREATE TABLE job (
       id               serial PRIMARY KEY,
       name             text   NOT NULL,
       is_doctor        bool   NOT NULL
);

CREATE TABLE employee (
       id               serial PRIMARY KEY,
       first_name       text   NOT NULL,
       last_name        text   NOT NULL,
       middle_name      text   NULL,
       phone            text   NULL,
       salary           money  NOT NULL,
       major_department integer REFERENCES department NOT NULL,
       job_id           integer REFERENCES job  NOT NULL
);

CREATE TABLE employment (
      employee_id          integer REFERENCES employee NOT NULL,
      department_id        integer REFERENCES department NOT NULL, 
      PRIMARY KEY (employee_id, department_id)
);

CREATE TABLE disease (
       id               serial PRIMARY KEY,
       name             text   NOT NULL,
       description      text   NULL,
       department_id    integer REFERENCES department NOT NULL
);

CREATE TYPE status AS ENUM ('Active', 'Cured', 'Not cured', 'Dead');

CREATE TABLE case_history (
       date1            date NOT NULL,
       date2            date NULL,
       patient_id       integer REFERENCES patient  NOT NULL,
       doctor_id        integer REFERENCES employee NOT NULL,
       disease_id       integer REFERENCES disease  NOT NULL,
       status           status                      NOT NULL,
       PRIMARY KEY (date1, patient_id, doctor_id, disease_id)   
);
COMMIT;

-- add constraints --
CREATE OR REPLACE FUNCTION is_doctor()
    RETURNS TRIGGER AS
$$
DECLARE
    res job.is_doctor%TYPE;
BEGIN
    SELECT is_doctor INTO res 
      FROM job 
      WHERE job.id = (
        SELECT job_id 
          FROM employee 
          WHERE employee.id = NEW.doctor_id
      );
    IF NOT res THEN 
      RAISE EXCEPTION 'Employee with id = % is not doctor', NEW.doctor_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER care_employee_should_be_a_doctor
    BEFORE INSERT OR UPDATE ON case_history 
    FOR EACH ROW
    EXECUTE PROCEDURE is_doctor();


CREATE OR REPLACE FUNCTION same_department()
    RETURNS TRIGGER AS
$$
DECLARE
BEGIN
    IF NOT (SELECT EXISTS(
       SELECT * FROM employment 
         WHERE employee_id = NEW.doctor_id AND 
         department_id = 
           (SELECT disease.department_id FROM disease 
             WHERE id = NEW.disease_id))
    ) THEN 
      RAISE EXCEPTION 'Doctor with id = % can not cure disease with id = %', NEW.doctor_id, NEW.disease_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER doctor_can_cure_disease_only_from_the_same_department
    BEFORE INSERT OR UPDATE ON case_history 
    FOR EACH ROW
    EXECUTE PROCEDURE same_department();

CREATE OR REPLACE FUNCTION is_dead()
    RETURNS TRIGGER AS
$$
DECLARE
BEGIN
    IF (SELECT EXISTS(SELECT * FROM case_history WHERE patient_id = NEW.patient_id AND status = 'Dead')
    ) THEN 
      RAISE EXCEPTION 'Patient with id = % is dead', NEW.patient_id;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER dead_patient
    BEFORE INSERT OR UPDATE ON case_history 
    FOR EACH ROW
    EXECUTE PROCEDURE is_dead();

-- function --
CREATE OR REPLACE FUNCTION leave_employee(eid employee.id%TYPE)
RETURNS void
AS $$
DECLARE
   cases        case_history%ROWTYPE;
   new_doctor   employee.id%TYPE;
BEGIN
  FOR cases IN
    SELECT * FROM case_history 
      WHERE doctor_id = employee_id AND status = 'Active'
  LOOP
    WITH doctor_business AS (
      SELECT doctor_id, COUNT(case_history.*) AS cnt 
        FROM case_history 
        WHERE case_history.doctor_id != eid AND
          status = 'Active' AND 
          doctor_id IN (
            SELECT employee.id 
              FROM employee, employment, job, disease 
              WHERE employee.id != eid AND
                employee.job_id = job.id AND 
                job.is_doctor = TRUE AND 
                employment.employee_id = employee.id AND 
                employment.department_id = department.id AND 
                department.id = disease.department.id AND
                disease.id = cases.disease_id                                    )
        GROUP BY doctor_id
    )
    UPDATE case_history 
      SET status = 'Not cured', date2 = now()
      WHERE date1 = cases.date1 AND
            patient_id = cases.patient_id AND
            doctor_id = cases.doctor_id AND
            disease_id = cases.disease_id;
    SELECT MAX(doctor_id) INTO new_doctor FROM doctor_business
      WHERE cnt in (SELECT MAX(cnt) from doctor_business);
    IF FOUND THEN
      INSERT INTO case_history 
        (date1, date2, patient_id, doctor_id, disease_id, status) 
        VALUES (now(), NULL, cases.patient_id, new_doctor, cases.disease_id, 'Active');
    END IF; 
  END LOOP; 
END;
$$ LANGUAGE plpgsql;

-- test data --
INSERT INTO patient (first_name, last_name, credentials) VALUES 
       ('Ivan', 'Ivanov', '0001'),
       ('Petr', 'Petrov', '0002'),
       ('Dmitriy', '', '0003'),
       ('Alexandr', '', '0005'),
       ('Darya', '', '0004'),
       ('Maria', '', '0006'),
       ('Sofya', '', '0007'),
       ('Anastasiya', '', '0008');

INSERT INTO job (name, is_doctor) VALUES
       ('Head Physician', TRUE),
       ('Doctor', TRUE),
       ('Nurse', FALSE);

INSERT INTO department (name) VALUES 
       ('Psychiatric'), ('Surgery'), ('Oncology');
 
INSERT INTO employee (first_name, last_name, salary, major_department, job_id)
    SELECT 'Hippocrates', '', 1000, department.id, job.id 
       FROM department, job
       WHERE department.name = 'Surgery' and job.name = 'Head Physician'
    UNION SELECT 'Avicenna', '', 900, department.id, job.id 
       FROM department, job
       WHERE department.name = 'Oncology' and job.name = 'Doctor'
    UNION SELECT 'Sigmund', 'Freud', 900, department.id, job.id 
       FROM department, job
       WHERE department.name = 'Psychiatric' and job.name = 'Doctor'
    UNION SELECT 'Gregory', 'House', 800, department.id, job.id 
       FROM department, job 
       WHERE department.name = 'Oncology' and job.name = 'Nurse'; 

INSERT INTO disease (name, department_id)
    SELECT 'Bipolar disorder', id FROM department 
        WHERE name = 'Psychiatric' 
    UNION SELECT 'Obsessive-compulsive disorder', id FROM department
        WHERE name = 'Psychiatric'
    UNION SELECT 'Appendicitis', id FROM department 
        WHERE name = 'Surgery'
    UNION SELECT 'Leukemia', id FROM department
        WHERE name = 'Oncology'
    UNION SELECT 'Carcinoma', id FROM department
        WHERE name = 'Oncology';

INSERT INTO employment (employee_id, department_id) 
    SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Hippocrates' AND 
              department.name = 'Surgery'
    UNION SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Hippocrates' AND 
              department.name = 'Psychiatric'
    UNION SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Hippocrates' AND 
              department.name = 'Oncology'    
    UNION SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Avicenna' AND 
              department.name = 'Surgery'
    UNION SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Avicenna' AND 
              department.name = 'Oncology'
    UNION SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Sigmund' AND 
              department.name = 'Psychiatric'
    UNION SELECT employee.id, department.id FROM employee, department
        WHERE employee.first_name = 'Gregory' AND 
              department.name = 'Oncology';

INSERT INTO case_history (date1, date2, patient_id, doctor_id, disease_id, status)
   SELECT now(), NULL::date, patient.id, employee.id, disease.id, 'Active'
      FROM patient, employee, disease 
      WHERE patient.credentials = '0001' AND
            employee.first_name = 'Hippocrates' AND
            disease.name = 'Bipolar Disorder'
   UNION SELECT now(), NULL::date, patient.id, employee.id, disease.id, 'Active'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0002' AND
            employee.first_name = 'Sigmund' AND
            disease.name = 'Obsessive-compulsive disorder'
   UNION SELECT now(), NULL::date, patient.id, employee.id, disease.id, 'Active'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0003' AND
            employee.first_name = 'Avicenna' AND
            disease.name = 'Appendicitis'
   UNION SELECT now(), now(), patient.id, employee.id, disease.id, 'Cured'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0004' AND
            employee.first_name = 'Avicenna' AND
            disease.name = 'Appendicitis'
   UNION SELECT now(), NULL::date, patient.id, employee.id, disease.id, 'Active'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0005' AND
            employee.first_name = 'Hippocrates' AND
            disease.name = 'Carcinoma'
   UNION SELECT now(), NULL::date, patient.id, employee.id, disease.id, 'Active'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0005' AND
            employee.first_name = 'Sigmund' AND
            disease.name = 'Bipolar Disorder'
   UNION SELECT now(), now(), patient.id, employee.id, disease.id, 'Dead'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0006' AND
            employee.first_name = 'Hippocrates' AND
            disease.name = 'Leukemia'
   UNION SELECT now(), now(), patient.id, employee.id, disease.id, 'Active'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0007' AND
            employee.first_name = 'Hippocrates' AND
            disease.name = 'Appendicitis'
   UNION SELECT now(), now(), patient.id, employee.id, disease.id, 'Active'::status
      FROM patient, employee, disease 
      WHERE patient.credentials = '0008' AND
            employee.first_name = 'Hippocrates' AND
            disease.name = 'Obsessive-compulsive disorder';
-- vies --
CREATE OR REPLACE VIEW active_patient AS 
    SELECT patient.id AS patient_id, 
           patient.first_name AS patient_fn, 
           patient.last_name AS patient_ln, 
           employee.id AS doctor_id, 
           employee.first_name AS doctor_fn, 
           employee.last_name AS doctor_ln, 
           disease.id AS disease_id, 
           disease.name AS disease_name, 
           department.id AS department_id, 
           department.name AS department_name
      FROM patient, employee, disease, department, case_history 
      WHERE case_history.patient_id = patient.id AND   
            case_history.doctor_id = employee.id AND
            case_history.disease_id = disease.id AND
            disease.department_id = department.id AND
            case_history.status = 'Active';

-- queries --
--case history of patient
SELECT patient.first_name, patient.last_name, disease.name, date1, date2, status 
    FROM case_history, patient, disease 
    WHERE patient.id = case_history.patient_id AND 
          disease.id = case_history.disease_id AND 
          patient.id = 1 
    ORDER BY date1 DESC;

--all doctors from specified department
SELECT employee.first_name, employee.last_name, job.name 
   FROM employee, employment, job, department 
   WHERE employee.job_id = job.id AND 
         job.is_doctor = TRUE AND 
         employment.employee_id = employee.id AND 
         employment.department_id = department.id AND 
         department.name = 'Psychiatric';

--all patients of this doctor at current time
SELECT patient_fn, patient_ln, disease_name, department_name
   FROM active_patient
   WHERE doctor_id = 1;

-- busyness --

