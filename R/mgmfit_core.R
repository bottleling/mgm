

mgmfit_core <- function(
  data, # data matrix, col=variables
  type, # data type for col 1:ncol; c=categorical, g=gaussian, p=poisson
  lev, # number of categories of categorical variables, continuous variables have level=1
  lambda.sel = "EBIC", # method for penalization parameter (lambda) -selection 
  folds = 10, # folds in case CV is used for lambda selection
  gam = .25, # tuning parameter for EBIC, in case EBIC is used for lambda selection
  d = 2, # maximal degree of the true graph
  rule.reg = "AND", # parameter-aggregation of categorical variables
  pbar = TRUE, # shows a progress bar if TRUE
  method = 'glm',  # which method should be used for each nodewise regression?
  missings = 'error', # handling of missing data
  weights = NA, # weights for observations 
  ret.warn = TRUE, # TRUE returns warnings, makes sense to switch off for time varying wrapper
  binary.sign = FALSE, # should we assign
  VAR = FALSE, # autoregressive model yes/no
  rs_indicator = NULL, # indicator to subset data for resampling (necessary because of VAR pipeline)
  threshtype = 'LW',
  ...
)

{
  
  # -------------------- Input checks ------------------
  
  
  # Later: take all arguments from (...)
  
  
  # ----- Calculate Aux Variables -----
  
  nNode <- ncol(data)
  
  # ----- Depreciated Messages -----
  
  if(!is.null(missings)) warning('missings is deprechiated. mgm does not support missing values anymore.')
  
  if(sum(is.na(data))>0) stop('No missing values permitted in the data matrix.')
  
  
  # ----- Basic Checks -----
  
  # Check on variable typee
  if(sum(!(type %in% c('c', 'g', 'p')))>0) stop("Only Gaussian 'g', Poisson 'p' or categorical 'c' variables allowed.")
  
  # IF VAR: change data structure (+++)
  if(VAR) {
    data <- VARreshape(as.matrix(data))
    lev <- c(lev, lev)
    type <- c(type, type)
  }
  
  # Apply rs_indicator:
  if(!is.null(rs_indicator)) {
    #checks:
    if(sum(!(rs_indicator %in% 1:nrow(data)))>0) stop('Subsampling indices specified that are not in the data.')
    #apply:
    data <- data[rs_indicator,]    
  }
  
  # get basic info #2
  n <- nrow(data) 
  c_ind <- which(type == "c") #indicator which variable categorical
  
  
  # For: binary.sign = TRUE: Are all binary variables coded (0,1)?
  if(binary.sign & 'c' %in% type) {
    ind_binary <- apply(data, 2, function(x) length(unique(x))) == 2
    n_binary <- sum(ind_binary)
    ind_ZeroOneCheck <- rep(NA, n_binary)
    if(n_binary>0) {
      for(i in 1:n_binary) { # loop over binary variables
        ind_ZeroOneCheck[i] <-  sum(unique(data[,which(ind_binary==TRUE)[i]]) %in% c(0,1)) != 2
      }
    }
    if(sum(ind_ZeroOneCheck)>0) stop('If binary.sign=TRUE, binary variables have to be coded as (0,1).')
  }
  
  # Initial Missing Value Check
  if(missings=='error') {
    ind_NA <- ind_NA2 <- apply(data, 1, function(x) sum(is.na(x))>0) #check for missing values  
    if(sum(ind_NA2)>0){
      stop(paste0('Missing values in cases ', paste(which(ind_NA2), collapse=' ')))
    }
  }
  
  ## weights and missing data handling
  # create weight vector
  if(is.na(weights[1])) weights <- rep(1,n) # if no weights are specified all weights are equal to 1 
  
  # missing data handling via setting weights to zero
  if(missings=='casewise.zw') {
    ind_NA <- apply(data, 1, function(x) sum(is.na(x))>0) #check for missing values  
    data[ind_NA,] <- 4121 # we pick an unlikely numeric category label; this is to collapse them later into availabel categories; this avoids problems with minimum P(L=l) requirement in binomial link in glmnet
    weights[ind_NA] <- 0
  }
  
  # further checks on input
  stopifnot(ncol(data)==length(type)) # type vector has to match data
  stopifnot(ncol(data)==length(lev)) # level vector has to match data
  if(sum(apply(data, 2, function(x) sum(class(x)!="numeric",class(x)!="integer")>1))>0) {
    stop("Only numeric/integer values permitted!")
  } 
  if(sum(apply(cbind(data[,type=="p"],rep(1,nrow(data))), 2, function(x) sum(x-round(x))))>0) {
    stop("Only integers permitted for Poisson random variables!")
  }
  
  # calculate adjusted N
  nadj <- round(sum(weights))
  
  # create storage for warning messages
  warn_list <- list()
  warn_count <- 1
  
  # Check minimum class probability (glmnet requirement)
  if (method == "glm") {
    if ("c" %in% type) {
      for (i in 1:length(c_ind)) {
        ii <- c_ind[i]
        cats <- unique(data[, ii])
        n_cat <- length(cats)
        rel_w_freq <- abs_freq <- rep(NA, n_cat)
        for (ca in 1:n_cat) {
          caa <- cats[ca]
          rel_w_freq[ca] <- sum(weights[data[, ii] == caa])
          abs_freq[ca] <- length(weights[data[, ii] == caa])
        }
        tb_norm <- rel_w_freq/sum(rel_w_freq)
        ind_toosmall <- (tb_norm < 10^-5) | (abs_freq<2)
        if (sum(ind_toosmall) > 0) {
          for (k in cats[ind_toosmall]) {
            prob <- rep(1, length(cats))
            prob[ind_toosmall == TRUE] <- 0
            data[data[, ii] == k, ii] <- sample(cats, 
                                                length(data[data[, ii] == k, ii]), replace = TRUE, 
                                                prob = prob)
            warn <- paste0("Category ", k, " in Variable ", 
                           ii, " has probability 10^-5 and was randomly collapsed into the remaining categories")
            if (ret.warn == TRUE & k!=.111) {
              warning(warn)
            }
            warn_list[[warn_count]] <- warn
            warn_count <- warn_count + 1
          }
        }
      }
    } 
  }
  
  
  # compare entered and empirical levels & give warnings if discrepancy
  if('c' %in% type) {
    emp_lev <- apply(data, 2, function(x) length(unique(x)))
    emp_lev[-c_ind] <- 1 # continuous
    check_lev <- emp_lev[c_ind] != lev[c_ind]
    for(w in 1:length(c_ind)) {
      if(check_lev[w]==TRUE) {
        warn <- paste0('For Variable ', c_ind[w], ' the specified and empirical categories differ (', lev[c_ind][w], ' vs. ', emp_lev[c_ind[w]], ')')
        if(ret.warn==TRUE) {warning(warn)}
        warn_list[[warn_count]] <- warn; warn_count <- warn_count + 1
      }
    }
  } else {
    emp_lev <- rep(1, nNode)
  }
  
  # zero variance? variables will be excluded from estimation
  ind_nzv <- apply(data, 2, var) != 0
  if(sum(ind_nzv)>0) {
    for(w in 1:length(ind_nzv)) {
      if(ind_nzv[w]==FALSE) {
        warn <- paste0("Variable ", w, " has zero variance and therefore no edges can be estimated.")
        if(ret.warn==TRUE) {warning(warn)}
        warn_list[[warn_count]] <- warn; warn_count <- warn_count + 1
      }
    }
  }
  
  data <- as.data.frame(data) # necessary for formula input & to assign factors
  
  # treat categoricals with only 1 category as gaussians 
  # (this is necessary because model.matrix() does not allow contrasts from 1 category;
  # it makes no difference for estimation)
  type[ind_nzv==FALSE] <- 'g'
  lev[ind_nzv==FALSE] <- emp_lev[ind_nzv==FALSE] <- 1
  
  # make categoricals factors
  for(cc in which(type=='c')) {
    data[,cc] <- as.factor(data[,cc]) 
  }
  
  
  # Check input of (...)
  
  # input <- list(...)
  # if(is.null(input$threshtype)) threshtype <- 'LW' # else threshtype = 'GLM'
  # 
  
  
  # +++++ prepare data for glmnet input ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #####
  
  #necessary for formula input
  if(!VAR){
    colnames(data)[1:nNode] <- paste("V",1:nNode, sep="") 
  } else {
    colnames(data)[1:nNode] <- paste("V",1:nNode, sep="") 
    colnames(data)[(nNode+1):(nNode*2)] <- paste("V",1:nNode,'_tm1', sep="")
  }
  
  # only use non-missing data for scaling
  data[!ind_NA , type=="g" & ind_nzv==TRUE] <- scale(data[!ind_NA, type=="g" & ind_nzv==TRUE]) #scale all gaussians to N(0,1)
  
  
  #progress bar
  if(pbar==TRUE) {
    pb <- txtProgressBar(min = 0, max=nNode, initial=0, char="-", style = 3)
  }
  
  node_models <- list() # storage for estimated parameters
  
  # +++++ estimation ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #####
  
  for(v in seq_len(nNode))
  {
    
    ## AR: If AR, define new data matrix for each v
    if(!VAR) {
      data_restr <- data
      type_restr <- type
      emp_lev_restr <- emp_lev
      vv <- v
    } else {
      vv <- 1
      data_restr <- data[,( -(1:nNode)[-v])]
      type_restr <- type[-((1:nNode)[-v])]
      emp_lev_restr <- emp_lev[-((1:nNode)[-v])]
    }
    
    if(v %in% which(ind_nzv)) # do estimation for variables with nonzero variance
    {
      
      # create design matrix
      if(d > (nNode - 1)) {
        stop("Order of interactions can be maximal the number of predictors!")
      } else if (d == 1){ form <- as.formula(paste(colnames(data_restr)[vv],"~ (.)"))
      } else { form <- as.formula(paste(colnames(data_restr)[vv],"~ (.)^",d)) }
      
      X <- model.matrix(form, data=data_restr)[,-1]
      
      ## select regularization parameter lambda with EBIC or CV:
      
      if(method=='glm') {
        
        # define link function
        if(type_restr[vv] == "c") {
          fam <- "multinomial"
        } else if(type_restr[vv] == "g" | type_restr[vv] == "e") { #should be inverse link for "e", but currently not avail. for glmnet
          fam <- "gaussian"
        } else if(type_restr[vv] == "p") {
          fam <- "poisson"
        }
        
        y <- data_restr[, vv]
        v_mod <- node.est(lambda.sel, y, fam, folds, emp_lev_restr, vv, n, nadj, gam, X, method, weights, type_restr)
        coefs <- v_mod$coefs
        EBIC <- v_mod$EBIC
        lambda_select <- v_mod$lambda_select
      }
      
      if(method=='linear') {
        
        fam <- "gaussian"
        
        # for categorical varables: create indicator variables, then linear regression
        if(type_restr[v]=='c') {
          
          u_lev <- unique(data_restr[,v])
          coefs <- list()
          
          for(el in 1:emp_lev_restr[v]) {
            EBIC <- list()
            lambda_select <- list()
            y <- (data_restr[,v] == u_lev[el])*1
            v_mod <- node.est(lambda.sel, y, fam, folds, emp_lev_restr, v, n, nadj, gam, X, method, weights, type_restr)
            coefs[[el]] <- v_mod$coefs
            EBIC[[el]] <- v_mod$EBIC
            lambda_select[[el]] <- v_mod$lambda_select
          }
          
          # for continuous variables: as above
        } else {
          y <- data_restr[, v]
          v_mod <- node.est(lambda.sel, y, fam, folds, emp_lev_restr, v, n, nadj, gam, X, method, weights, type_restr)
          coefs <- v_mod$coefs
          EBIC <- v_mod$EBIC
          lambda_select <- v_mod$lambda_select
        }
        
      }
      
      # calculate threshold
      coefsm <- matrix(do.call(rbind,lapply(coefs, as.numeric)),nrow=emp_lev_restr[vv])[,-1] # all paramters (no intercepts) in one vector
      
      # Select type of tau-threshold (beta min condition), depending on which theory we use (loh + wainwright vs. our own glm-based proof)
      if(threshtype == 'LW') {
        threshold <- sqrt(d) * sqrt(sum(coefsm^2)) * sqrt(log(nNode)/nadj) 
      } else {
        threshold <- d * sqrt(log(nNode)/nadj)
      }
      
    } else {
      
      # for variables with zero variance we mimic glmnet output with all parameters = 0, 
      #   so I can use the same postprocessing below
      
      # create zero estimates in glmnet structure
      type_mv <- type_restr[-vv]
      emp_lev_mv <- emp_lev_restr[-vv]
      n_pred <- sum(c(emp_lev_mv[type_mv!='c'], emp_lev_mv[type_mv=="c"]-1)) # number of dummy predictors
      
      # see above; we treat categorical variables with 1 category as gaussians; therefore coefs is a matrix and not a list containing matrices
      
      # if(type[v]=='c')
      # {
      #   
      # } else {
      #   
      # }
      
      
      
      coefs <- matrix(0, nrow=n_pred+1, ncol=1) # n_pred+1 adds the intercept
      lambda_select <- NULL
      threshold <- NULL # does nothing, but need numeric value to avoid error
      EBIC <- NULL
      
    }
    
    # save model parameters
    node_models[[v]] <- list("coefs"=coefs, "lambda"=lambda_select, "threshold"=threshold, "EBIC"=EBIC)
    
    # update progress bar
    if(pbar==TRUE) { setTxtProgressBar(pb, v) }
    
  } # end variable-loop
  
  
  # +++++ bring parameters in matrix form ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #####
  
  if(VAR) {
    type_sh <- type[1:(length(type)/2)]
    emp_lev_sh <-  emp_lev[1:(length(emp_lev)/2)]
  } else {
    type_sh <- type
    emp_lev_sh <- emp_lev
  }
  
  mpm <- matrix(NA, sum(emp_lev_sh), sum(emp_lev_sh)) # model parameter matrix
  
  # create dummy variables
  dummy_est.par <- list() # logical vector: which parameters are estimated in each column?
  dummy_par.var <- list() # indicating which parameter 'belongs' to which variable
  for(v in 1:nNode) {
    if(emp_lev[v]==1) {
      dummy_est.par[[v]] <- TRUE
      dummy_par.var[[v]] <- v
    }
    if(emp_lev[v]>1){
      dummy_est.par[[v]] <- c(FALSE, rep(TRUE, emp_lev[v] - 1))
      dummy_par.var[[v]] <- rep(v, emp_lev[v])
    }
  }
  dummy_est.par <- unlist(dummy_est.par)
  dummy_par.var <- unlist(dummy_par.var)
  
  # for normal mgmfit
  if(!VAR) {
    
    # loop over nodes & fill mpm
    
    for(v in 1:nNode) {
      mod <- node_models[[v]] # get model object
      
      for(cat in 1:emp_lev[v]) {
        # get parameters from list
        if(emp_lev[v]==1) { 
          coefs.v <- mod$coefs 
        } else { 
          coefs.v <- mod$coefs[[cat]] 
        }
        coefs.v.cut <- coefs.v[2:(sum(dummy_est.par[dummy_par.var!=v])+1),1] # cut out relevant part (no intercept & d>2 interactions)
        
        # apply thresholding
        coefs.v.cut[abs(coefs.v.cut)<mod$threshold] <- 0
        
        # fill in
        dummy_est.par.v <- dummy_est.par
        dummy_est.par.v[dummy_par.var==v] <- FALSE
        
        if(sum(emp_lev[v])==1) { 
          mpm[v==dummy_par.var,][dummy_est.par.v] <- coefs.v.cut
        } else {
          mpm[v==dummy_par.var,][cat,][dummy_est.par.v] <- coefs.v.cut
        }
      }
    }
    
  } else {
    
    ## for VAR  
    # loop over nodes & fill mpm
    for(v in 1:nNode) {
      mod <- node_models[[v]] # get model object
      
      for(cat in 1:emp_lev_sh[v]) {
        # get parameters from list
        if(emp_lev_sh[v]==1) { 
          coefs.v <- mod$coefs 
        } else { 
          coefs.v <- mod$coefs[[cat]] 
        }
        coefs.v.cut <- coefs.v[2:(sum(dummy_est.par)+1),1] # cut out relevant part (no intercept & d>2 interactions)
        
        # apply thresholding
        coefs.v.cut[abs(coefs.v.cut)<mod$threshold] <- 0
        
        # fill in
        dummy_est.par.v <- dummy_est.par
        #dummy_est.par.v[dummy_par.var==v] <- FALSE
        
        if(sum(emp_lev[v])==1) { 
          mpm[v==dummy_par.var,][dummy_est.par.v] <- coefs.v.cut
        } else {
          mpm[v==dummy_par.var,][cat,][dummy_est.par.v] <- coefs.v.cut
        }
      } # end For cat
    }
    
    
  }
  
  
  
  # +++++ collapse across categorical interactions to get MRF ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #####
  
  adjmat <- matrix(NA,nNode,nNode)
  for(i in 1:nNode) {
    for(j in 1:nNode) {
      adjmat[i, j] <- mean(abs(mpm[dummy_par.var==i, dummy_par.var==j]), na.rm=TRUE)
    }
  }
  
  # Across regressions: apply AND or OR rule - not in VAR case
  adjmat.f <- adjmat
  
  if(!VAR) {
    for(i in 1:nNode) {
      for(j in 1:nNode) {
        if(rule.reg=='OR') {
          adjmat.f[i, j] <- (sum(adjmat[i,j],adjmat[j,i])/2)
        } else {
          adjmat.f[i, j] <- (sum(adjmat[i,j],adjmat[j,i])/2) * (adjmat[j,i]!=0 & adjmat[i,j]!=0)*1  
        }
      }
    }
  }
  
  
  #### Set coefficients in coefficient list (glmnet structure) to zero to enforce the AND-rule in predict.mgm()
  
  # not used currently, because causes problems with intercept scaling of glmnet models
  
  # if(rule.reg == 'AND') {
  #   # We go two steps backwards: 1) first we write the AND-rule-implied zeros into the model parameter matrix mpm
  #   #                            2) then we write from the mpm in the coefficient lists,
  #   #                            that way I only have to invert the above code
  #   
  #   
  #   # Step 1:
  #   mpm_zeros <- mpm
  #   for(i in 1:nNode) {
  #     for(j in 1:nNode) {
  #       mpm_zeros[dummy_par.var==i, dummy_par.var==j] <- rep(abs(adjmat.f[i,j])>0, length(mpm[dummy_par.var==i, dummy_par.var==j]))
  #     }
  #   }
  #   
  #   # Step 2:
  #   
  #   # for normal mgmfit
  #   if(!VAR) {
  #     
  #     # loop over nodes & fill mpm
  #     
  #     for(v in 1:nNode) {
  #       mod <- node_models[[v]] # get model object
  #       
  #       for(cat in 1:emp_lev[v]) {
  #         # get parameters from list
  #         if(emp_lev[v]==1) { 
  #           coefs.v <- mod$coefs 
  #         } else { 
  #           coefs.v <- mod$coefs[[cat]] 
  #         }
  #         coefs.v.cut <- coefs.v[2:(sum(dummy_est.par[dummy_par.var!=v])+1),1] # cut out relevant part (no intercept & d>2 interactions)
  #         
  #         # apply thresholding
  #         coefs.v.cut[abs(coefs.v.cut)<mod$threshold] <- 0
  #         
  #         # fill in
  #         dummy_est.par.v <- dummy_est.par
  #         dummy_est.par.v[dummy_par.var==v] <- FALSE
  #         
  #         if(sum(emp_lev[v])==1) { 
  #           coefs.v.cut <- mpm[v==dummy_par.var,][dummy_est.par.v] * mpm_zeros[v==dummy_par.var,][dummy_est.par.v]
  #         } else {
  #           coefs.v.cut <- mpm[v==dummy_par.var,][cat,][dummy_est.par.v]  * mpm_zeros[v==dummy_par.var,][cat,][dummy_est.par.v]
  #         }
  #         
  #         if(emp_lev[v]==1) { 
  #           mod$coefs[2:(sum(dummy_est.par[dummy_par.var!=v])+1),1] <- coefs.v.cut
  #         } else { 
  #           mod$coefs[[cat]][2:(sum(dummy_est.par[dummy_par.var!=v])+1),1] <- coefs.v.cut
  #         }
  #       }
  #       node_models[[v]]$coefs <- mod$coefs # put back in
  #     }
  #     
  #   } else {
  #     
  #     ## for VAR  
  #     # loop over nodes & fill mpm
  #     for(v in 1:nNode) {
  #       mod <- node_models[[v]] # get model object
  #       
  #       for(cat in 1:emp_lev_sh[v]) {
  #         # get parameters from list
  #         if(emp_lev_sh[v]==1) { 
  #           coefs.v <- mod$coefs 
  #         } else { 
  #           coefs.v <- mod$coefs[[cat]] 
  #         }
  #         coefs.v.cut <- coefs.v[2:(sum(dummy_est.par)+1),1] # cut out relevant part (no intercept & d>2 interactions)
  #         
  #         # apply thresholding
  #         coefs.v.cut[abs(coefs.v.cut)<mod$threshold] <- 0
  #         
  #         # fill in
  #         dummy_est.par.v <- dummy_est.par
  # 
  #         if(sum(emp_lev[v])==1) { 
  #           coefs.v.cut <- mpm[v==dummy_par.var,][dummy_est.par.v] * mpm_zeros[v==dummy_par.var,][dummy_est.par.v]
  #         } else {
  #           coefs.v.cut <- mpm[v==dummy_par.var,][cat,][dummy_est.par.v]  * mpm_zeros[v==dummy_par.var,][cat,][dummy_est.par.v]
  #         }
  #         
  #         if(emp_lev[v]==1) { 
  #           mod$coefs[2:(sum(dummy_est.par)+1),1] <- coefs.v.cut
  #         } else { 
  #           mod$coefs[[cat]][2:(sum(dummy_est.par)+1),1] <- coefs.v.cut
  #         }
  #         
  #       } # end For cat
  #       node_models[[v]]$coefs <- mod$coefs # put back in
  #     }
  #     
  #   } # end if VAR
  #   
  # }
  # 
  
  # +++++ extract sign matrix ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ 
  
  # A) Recover signs of continuous interactions
  
  signs <- signs_recov <- matrix(NA, nNode, nNode)
  signs[adjmat.f!=0] <- 0
  signs_recov[adjmat.f!=0] <- 1
  ind <- which(dummy_par.var %in% which(type_sh!='c')) # columns in model parameter matrix not belonging to categorical variables
  
  if(rule.reg=='AND') {
    signs[type_sh!='c', type_sh!='c'] <- sign(mpm[ind,ind]) 
    signs_recov[type_sh!='c', type_sh!='c'] <- sign(mpm[ind,ind]) 
    
    # for OR-rule: we have to consider both directions and collapse
  } else {
    sign_raw <- sign(mpm[ind,ind])
    sign_raw <- sign_raw + t(sign_raw)
    sign_raw[sign_raw==2] <- 1
    sign_raw[sign_raw==-2] <- -1
    signs[type_sh!='c', type_sh!='c'] <- sign_raw
    signs_recov[type_sh!='c', type_sh!='c'] <- sign_raw
  }
  
  
  # B) Recover signs of interactions involving binary variables
  #  (Note that here we implicitly take care of the case rule.reg=OR, because we have to loop through the model parameter matrix mpm anways)
  
  if(binary.sign) {
    
    signs_binary <- matrix(NA, nNode, nNode)
    
    # B.1) loop over all interactions: binary <- binary/continuous
    for(i in which(ind_binary[1:nNode])) { # only loop over binary edges;
      for(j in 1:nNode) {
        
        if(type[j] == 'c') {
          if(emp_lev[j]==2) binary_pars <- mpm[dummy_par.var==i, dummy_par.var==j][,-1] # only for binary interactions
        } else {
          binary_pars <- mpm[dummy_par.var==i, dummy_par.var==j]
        }
        
        signs_binary[i, j] <- sign(binary_pars)[2] # if positive relationship, the second parameter (predicting category 1 of i) has a positive
      }
    }
    
    # B.2) loop over all interactions: continous <- binary ( we need B.1 and B.2 because of the or Rule and VAR models)
    for(i in which(type[1:nNode]=='g')) { # only loop over binary edges;
      for(j in which(ind_binary[1:nNode])) {
        
        binary_pars <- mpm[dummy_par.var==i, dummy_par.var==j][-1] 
        
        signs_binary[i, j] <- sign(binary_pars) # if positive relationship, the second parameter (predicting category 1 of i) has a positive
      }
    }
    
    signs_binary[signs_binary==0] <- NA # kill zeros, which are not killed by below (signs[adjmat.f==0] <- NA) in case of OR-rule
    
    # make symmetric
    signs_binary[is.na(signs_binary)] <-  t(signs_binary)[is.na(signs_binary)]
    
    # write into sign matrix
    signs[!is.na(signs_binary)] <- signs_binary[!is.na(signs_binary)]
    signs_recov[!is.na(signs_binary)] <- signs_binary[!is.na(signs_binary)]
    
  }
  
  # Make sure that everything that is zero stays zero
  signs[adjmat.f==0] <- NA
  signs_recov[adjmat.f==0] <- NA
  
  
  # C) Create edgeColor Matrix
  
  edgeColor <- matrix('black', nNode, nNode)
  edgeColor[signs==0] <- 'grey'
  edgeColor[signs==1] <- 'darkgreen'
  edgeColor[signs==-1] <- 'red'
  
  
  # +++++ prepare output ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++ #####
  
  #dichotomize
  adj <- (adjmat.f!=0)*1
  
  # zeros in diagonal
  if(!VAR) {
    diag(adj) <- 0
    diag(adjmat.f) <- 0
  }
  
  # get back to right length of type/lev vector for output
  if(VAR) {
    type <- type[1:(length(type)/2)] 
    lev <- type[1:(length(lev)/2)] 
  }
  
  
  ## call
  call <- list('type'=type, 
               'lev'=emp_lev[1:nNode], 
               'lambda.sel'=lambda.sel, 
               'folds'=folds, 
               'gam'=gam, 
               'd'=d, 
               'rule.reg'=rule.reg, 
               'method'=method, 
               'weights'=weights, 
               'ret.warn'=ret.warn)
  
  outlist <- list('call'=call, 
                  "adj"=adj, 
                  "wadj"=adjmat.f, 
                  'mpar.matrix' = mpm, 
                  'signs'=signs, 
                  'signs_recov'=signs_recov, 
                  'edgecolor'=edgeColor,
                  "node.models" = node_models, 
                  "par.labels"=dummy_par.var, 
                  'warnings'=warn_list ,
                  'variance.check' = ind_nzv)
  
  # Assign Model Class
  if(VAR) {  class(outlist) <- c('var', 'mgm') } else {   class(outlist) <- c('mgm')}
  
  
  return(outlist)
} 

