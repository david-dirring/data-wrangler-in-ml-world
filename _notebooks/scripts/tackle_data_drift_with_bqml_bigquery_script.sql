declare auc_min_to_fail float64 ;
declare sql string;
declare auc float64; 
declare mess_up_data int64; 
declare project_name string; declare dataset_name string; declare table_name string; declare main_table_name string; declare model_name string; declare train_table_name string; declare test_inference_table_name string;

set project_name = 'blog-examples'; #put your project name here
set dataset_name = 'data_drift';  #put your dataset name here, you'll likely need to create it if you don't have it already
set table_name = 'data_drift_illustrated'; 
set auc_min_to_fail = .65;
set mess_up_data = 1; # 1 means run update statement to mess up data; 0 means dont mess up data


#### inputs are above, should not need to modify anything below ####

set main_table_name = "`" || project_name || "." || dataset_name || "." || table_name || "`";
set train_table_name = "`" || project_name || "." || dataset_name || "." || table_name || "_train`";
set test_inference_table_name = "`" || project_name || "." || dataset_name || "." || table_name || "_test_inference`" ;
set model_name = "`" || project_name || "." || dataset_name || "." || table_name || "_model`";


set sql = FORMAT("""
    #### I am grabbing a dataset from public bigquery. Historical liquor sales in Iowa. Let's pretend we work in Iowa at govt agency where we need to forecast liquor sales for whatever reason  ####
    create or replace table %s
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR)) #table will drop in 24 hours
    as 
        with liquor_sales_wk_zip_cat_vendor as ( 
            SELECT 
                DATE(TIMESTAMP_TRUNC(TIMESTAMP(DATE), WEEK)) as sale_wk_bgn_dt
                , DATE(TIMESTAMP_TRUNC(TIMESTAMP(DATE), WEEK)) + 6 as sale_wk_end_dt
                , cast(zip_code as string) as store_zip_code # making sure this is a string, as I want BQML to see it as a categorical
                , category_name
                , vendor_name
                , item_description
                , sum(volume_sold_gallons) as volume_sold_gallons
            FROM `bigquery-public-data.iowa_liquor_sales.sales`
            where date between 
                (select max(date) - ((7*104)+28) from `bigquery-public-data.iowa_liquor_sales.sales`) --getting 104 weeks, starting from 4 weeks ago
                and (select max(date) - 28  from `bigquery-public-data.iowa_liquor_sales.sales`) --max date will be 4ish weeks ago
            group by 1,2,3,4,5,6
            # order by 1 desc # don't put order by in a CTE, not a good practice, doing here for illustrative purposes
        )
        #### I actually recommend to throw the data into a tool like Tableau at this point so you can get to know the data, but I will spare you of a David Going On About Tableau rant for the time being.  

        , check_dates as (
            select distinct 
                case when row_number() over(order by sale_wk_end_dt desc) <= 3 then 'test-inference' # this is the most recent 3 week period
                    when row_number() over(order by sale_wk_end_dt desc) <= 6 then 'validation' # this is the holdout set, I use this as unseen data, test my model against this dataset
                    when row_number() over(order by sale_wk_end_dt desc) <= 9 then 'test' # as I train a model, I'll test against this dataset during the epochs
                    else 'train' --this is the training data
                end as train_or_test
                , sale_wk_bgn_dt, sale_wk_end_dt
            from (
                select distinct sale_wk_bgn_dt, sale_wk_end_dt  # rolling up weeks so I can easily get row_number
                from liquor_sales_wk_zip_cat_vendor
            )
            order by sale_wk_end_dt desc

        )

        select s.* , d.train_or_test 
        from liquor_sales_wk_zip_cat_vendor s
            inner join check_dates d on s.sale_wk_end_dt = d.sale_wk_end_dt
        
        ; 
"""
, (select main_table_name) 
); 

select sql;
execute immediate(sql);


set sql = FORMAT("""
    #### this is the table we would normally use in training ####
    create or replace table %s
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR))  #table will drop in 24 hours
    as 
        select * from %s
        where train_or_test in ('train','test','validation')
    ;
"""
, (select train_table_name) 
, (select main_table_name) 

); 

select sql;
execute immediate(sql);


set sql = FORMAT("""
    #### this is the table we would use in our real "test", where we have to load in the data live from the source, usually this is a complicated process involving tons of scripts to pull the features. ####
    create or replace table %s
        OPTIONS (expiration_timestamp=TIMESTAMP_ADD(CURRENT_TIMESTAMP(), INTERVAL 24 HOUR))  #table will drop in 24 hours
    as 
        select * from %s
        where train_or_test in ('test-inference')
    ;
"""
, (select test_inference_table_name) 
, (select main_table_name) 

); 

select sql;
execute immediate(sql);


set sql = FORMAT("""
    #### we update the category_name to null... simulating an issue with an upstream data source ####
    update %s
    set category_name = null
    where 1=%s #if user puts 1, then we update because 1 always equals 1
    ;
"""
, (select test_inference_table_name) 
, (select cast(mess_up_data as string)) #I guess we have to convert to string to put inside a string
); 

select sql;
execute immediate(sql);




set sql = FORMAT("""

    CREATE OR REPLACE MODEL %s
    OPTIONS( 
        MODEL_TYPE='LOGISTIC_REG'
        , input_label_cols=['label']
    ) AS
        with get_train as (
            select store_zip_code, category_name, vendor_name --grab the 3 fields that we use in the model.  In prod I actually grab these columns using dynamic sql
                , cast(0 as int64) as label --mark the train records as 0  
            from %s
            order by rand() 
            limit 5000
        )
        
        , get_test_inference as (
            select store_zip_code, category_name, vendor_name --grab the 3 fields that we use in the model.  In prod I actually grab these columns using dynamic sql
                , cast(1 as int64) as label --mark the test-inference records as 1  
            from %s
            order by rand() 
            limit 5000
        )

        select * from get_train
            union all 
        select * from get_test_inference
    ; 
    
"""
, (select model_name) 
, (select train_table_name) 
, (select test_inference_table_name) 

); 

select sql;
execute immediate(sql);




set sql = FORMAT("""

    create or replace temp table auc_and_top_contributors as 
        SELECT
            case when e.roc_auc <= %s then 'no issues' else 'yikes, dig in!' end as is_there_an_issue
            , round(e.roc_auc,4) as auc      
            , w.processed_input as feature_name
            , round(w.weight,4) as weight
            , cw.category
            , round(cw.weight,4) as categorical_weight
        FROM
            ML.WEIGHTS (MODEL  %s 
                ,STRUCT(true AS standardize)
            ) w
            , unnest(category_weights) as cw
            , ML.EVALUATE(MODEL  %s  ) e
        order by coalesce(abs(w.weight),cw.weight) desc
        limit 8
    ; 
"""
    , (select cast(auc_min_to_fail as string))
    , (select model_name) 
    , (select model_name) 
); 

select sql; execute immediate(sql);

select * from auc_and_top_contributors; 

if (SELECT distinct auc from auc_and_top_contributors) > auc_min_to_fail then --auc_min_to_fail then --if auc is above x, then fail the job
    select ERROR("YIKES! you have a data issue!");
end if;

