declare mess_up_data int64; 
set mess_up_data = 1; # 1 means run update statement to mess up data; 0 means dont mess up data

#### inputs are above, should not need to modify anything below ####

--create the dataset if it doesn't exist
    CREATE SCHEMA IF NOT EXISTS data_drift_for_blog; 

-- Grab a dataset from public bigquery. 
-- I chose the fraud detection table from the ML_DATASETS dataset. 
-- Let's pretend we work for a company where we only have to predict fraud CC activity.
    create or replace table data_drift_for_blog.fraud
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)) #table will drop in 24 hours
    as 
        select 
            case  when ABS(MOD(FARM_FINGERPRINT(cast(time as string)), 100)) < 70 then 'train' 
                    when ABS(MOD(FARM_FINGERPRINT(cast(time as string)), 100)) < 80 then 'test' 
                    when ABS(MOD(FARM_FINGERPRINT(cast(time as string)), 100)) < 90 then 'validation'
                    when ABS(MOD(FARM_FINGERPRINT(cast(time as string)), 100)) < 100 then 'test-inference' 
            end as train_or_test
            , fraud.* except(Time, Amount, Class)
        FROM `bigquery-public-data.ml_datasets.ulb_fraud_detection` fraud
    ;                

--creating my train data
    create or replace table data_drift_for_blog.fraud_train
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR))  #table will drop in 24 hours
    as 
        select * from data_drift_for_blog.fraud
        where train_or_test in ('train')
    ;


--creating my test-inference table (I would normally have processes to grab these features for each record)
    create or replace table data_drift_for_blog.fraud_test_inference
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR))  #table will drop in 24 hours
    as 
        select * from data_drift_for_blog.fraud
        where train_or_test in ('test-inference')
    ;

--if user wants to 'mess up the data', set v15 field to be 5000 on all records
    if mess_up_data = 1 then 
            update  data_drift_for_blog.fraud_test_inference
            set v15 = 5000
            where true
            ;
    end if; 


-- grab 50k random rows from train, 50, random rows from test-inference
-- create logistic_regression model to predict where the row came from
    CREATE OR REPLACE MODEL data_drift_for_blog.fraud_model
    OPTIONS( 
        MODEL_TYPE='LOGISTIC_REG'
        , input_label_cols=['label']
    ) AS
        with get_train as (
            select * except(train_or_test) --grab all the fields I use for training
                , cast(0 as int64) as label --mark the train records as 0  
            from data_drift_for_blog.fraud_train
            order by rand() 
            limit 10000
        )
        
        , get_test_inference as (
            select * except(train_or_test) --grab all the fields I use for training
                , cast(1 as int64) as label --mark the test-inference records as 1  
            from data_drift_for_blog.fraud_test_inference
            order by rand() 
            limit 10000
        )
        select * from get_train
            union all 
        select * from get_test_inference
    ; 



--create a table to show the top contributing features to the high auc
   create or replace table data_drift_for_blog.fraud_auc_and_top_contributors
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR))  #table will drop in 24 hours
    as     
        SELECT
            case when e.roc_auc <= .65 then 'no issues' else 'yikes, dig in!' end as is_there_an_issue
            , round(e.roc_auc,4) as auc      
            , w.processed_input as feature_name
            , round(w.weight,4) as weight
            , cw.category
            , round(cw.weight,4) as categorical_weight
        FROM
            ML.WEIGHTS (MODEL  data_drift_for_blog.fraud_model 
                ,STRUCT(true AS standardize)
            ) w
                left join unnest(category_weights) as cw
            , ML.EVALUATE(MODEL  data_drift_for_blog.fraud_model  ) e
        order by coalesce(abs(w.weight),cw.weight) desc
    ; 


    select * from data_drift_for_blog.fraud_auc_and_top_contributors; 

--check if AUC is above your threshold, if so fail the script. Put this whole process in a BQ Procedure for easy reusability.
    if (SELECT distinct auc from data_drift_for_blog.fraud_auc_and_top_contributors) > .65 then 
        select ERROR("YIKES! you have a data issue!");
    end if;



