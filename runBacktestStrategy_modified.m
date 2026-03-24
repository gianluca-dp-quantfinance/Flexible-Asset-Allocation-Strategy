function [equity_tt, drawdown_tt, weights_tt] = runBacktestStrategy_modified(params, prices_daily, prices_monthly, asset_names)
% Backtest basato su 3 fattori ex-ante:
%   (1) Momentum relativo (skip-month)
%   (2) Downside semideviation (rischio downside)
%   (3) Correlation 
% Pesi proporzionali allo score combinato
%
%   Input:
%       params : struct con parametri strategia
%       prices_daily, prices_monthly : tabelle prezzi (Date + asset)
%       asset_names : cell array nomi asset
%
%   Output:
%       equity_tt, drawdown_tt, weights_tt

    disp(['--- Esecuzione strategia (3-factors): ', params.name, ' ---']);

    %% 0) Parametri
    lookback  = params.lookback_momentum;    % mesi per momentum
    n_assets  = numel(asset_names);
    LB_V      = params.lookback_volatility;  % mesi per semideviation
    LB_C      = params.lookback_correlation; % mesi per downside correlation
    topN      = params.top_n_assets;

   %% 1) Momentum relativo 
    momentum_matrix = nan(height(prices_monthly), n_assets);
    for t = lookback+1:height(prices_monthly)
    momentum_matrix(t,:) = log(prices_monthly{t,:} ./ prices_monthly{t-lookback,:});
    end
    momentum_table = array2timetable(momentum_matrix, ...
    'RowTimes', prices_monthly.Date, ...
    'VariableNames', asset_names);

  %% 2) Calcolo semideviazione standard rolling dai rendimenti giornalieri

% Estrai solo colonne numeriche da prices_daily
numVars = varfun(@isnumeric, prices_daily, 'OutputFormat','uniform');
prezziD = prices_daily{:, numVars};
datesD  = prices_daily.Date;

% Rendimenti giornalieri log
dailyR  = diff(log(prezziD));
datesR  = datesD(2:end);

n_assets = size(dailyR,2);
vol_matrix = nan(height(prices_monthly), n_assets);

% Loop sui mesi
for t = LB_V+1:height(prices_monthly)

    % Inizio/fine finestra basata su mesi
    startDate = dateshift(prices_monthly.Date(t-LB_V), 'start', 'month');
    endDate   = dateshift(prices_monthly.Date(t), 'end', 'month');

    % Seleziona rendimenti giornalieri nella finestra
    mask   = (datesR >= startDate & datesR <= endDate);
    window = dailyR(mask,:);

    % Calcola semideviazione standard se ci sono dati validi
    if ~isempty(window)
        neg_returns = window;
        neg_returns(window > 0) = NaN;  % Considera solo rendimenti negativi
        vol_matrix(t,:) = std(neg_returns, 0, 1, 'omitnan');
    end
end

% Tabella finale 
vol_table = array2timetable(vol_matrix, ...
    'RowTimes', prices_monthly.Date, ...
    'VariableNames', asset_names);


    %% 3) Calcolo correlazione rolling dai rendimenti giornalieri

corr_matrix = nan(height(prices_monthly), n_assets);
for t = LB_C+1:height(prices_monthly)

    % finestra di lookback di LB_C mesi (dal mese t-LB_C incluso a t incluso)
    startDate = dateshift(prices_monthly.Date(t-LB_C), 'start','month');
    endDate   = dateshift(prices_monthly.Date(t),      'end','month');

    % seleziona rendimenti giornalieri dentro la finestra
    mask   = (datesR >= startDate & datesR <= endDate);
    window = dailyR(mask,:);

    if size(window,1) > 2
        R = corr(window, 'Rows','pairwise');   % matrice NxN

        % togli la diagonale (autocorrelazione = 1)
        R(1:size(R,1)+1:end) = NaN;

        % media delle correlazioni assolute per ogni asset
        avgCorr = mean(abs(R), 2, 'omitnan')';

        corr_matrix(t,:) = avgCorr;   % salva lo score per tutti gli asset al mese t
    end
end

corr_table = array2timetable(corr_matrix, ...
    'RowTimes', prices_monthly.Date, ...
    'VariableNames', asset_names);

%% 4) Ranking momentum (per R/RA)
ranks_mom = tiedrank(momentum_table{:,:}')';  % rank per riga
    
%% 5) Selezione asset e costruzione pesi
weights = zeros(height(prices_monthly), n_assets);

% trova indice del risk-free già dentro ai dati
rf_idx = find(strcmp(asset_names, 'W1GE Index'));

for t = 1:height(prices_monthly)
    mom_t  = momentum_table{t,:};
    vol_t  = vol_table{t,:};
    corr_t = corr_table{t,:};
    abs_mask = mom_t > 0;   % filtro A: momentum assoluto

    if t <= lookback || all(isnan(mom_t))
        continue;
    end

    % --- Caso RAV / RAVC ---
    if (params.w_volatility > 0 || params.w_correlation > 0)
        % ranking momentum
        r_mom = tiedrank(mom_t);

        % ranking volatilità invertita
        if any(~isnan(vol_t))
            r_vol = tiedrank(-vol_t);
        else
            r_vol = zeros(size(mom_t));
        end

        % ranking correlazione invertita
        if any(~isnan(corr_t))
            r_corr = tiedrank(-corr_t);
        else
            r_corr = zeros(size(mom_t));
        end

        % score combinato
        score = r_mom + params.w_volatility * r_vol + params.w_correlation * r_corr;

        % selezione top N
        [~, idx_sorted] = maxk(score, topN);

        % applica filtro A
        if params.use_abs_momentum_filter
            idx_sorted = idx_sorted(abs_mask(idx_sorted));
        end

        if ~isempty(idx_sorted)
            % Pesi proporzionali allo score^gamma
            s = score(idx_sorted);
            s = max(s, 1e-8);                           % evita zeri o negativi
            if isfield(params,'gamma_score')
                s = s .^ params.gamma_score;
            end
            w_sel = s / sum(s);
        
            % Applica cap opzionale
            if isfield(params,'weight_cap') && params.weight_cap > 0
                w_sel = min(w_sel, params.weight_cap);
                w_sel = w_sel / sum(w_sel);              % rinormalizza
            end
        
            % Assegna pesi
            weights(t, idx_sorted) = w_sel;
        
            % fallback sul risk-free se meno di topN asset validi
            n_valid = numel(idx_sorted);
            if n_valid < topN
                weights(t, rf_idx) = (topN - n_valid) / topN;
            end
        else
            weights(t, rf_idx) = 1;
        end

% --- Caso R / RA ---
    else
        [~, idx_sorted] = maxk(ranks_mom(t,:), topN);
    
        % filtro A basato su momentum del mese precedente
        if params.use_abs_momentum_filter && t > 1
            mom_prev = momentum_table{t-1,:};       % mese precedente
            abs_mask = mom_prev > 0;                % filtro assoluto laggato
            idx_sorted = idx_sorted(abs_mask(idx_sorted));
        end
    
        if ~isempty(idx_sorted)
            s = mom_t(idx_sorted);
            s = max(s, 1e-8);
            if isfield(params,'gamma_score')
                s = s .^ params.gamma_score;
            end
            w_sel = s / sum(s);
    
            if isfield(params,'weight_cap') && params.weight_cap > 0
                w_sel = min(w_sel, params.weight_cap);
                w_sel = w_sel / sum(w_sel);
            end
    
            weights(t, idx_sorted) = w_sel;
        else
            weights(t, rf_idx) = 1;
        end
    end

end
    
    weights_table = array2timetable(weights, ...
        'RowTimes', prices_monthly.Date, ...
        'VariableNames', asset_names);

    %% 5) Rendimenti
    monthly_returns = log(prices_monthly{2:end,:} ./ prices_monthly{1:end-1,:});
    dates_returns   = prices_monthly.Date(2:end);

    % pesi calcolati a t-1, applicati a t
    W = weights_table{1:end-1,:};
    W(1:lookback,:) = 0;

    port_ret = sum(W .* monthly_returns, 2, 'omitnan');

    %% 6) Equity e Drawdown
    initial_capital = 100000;
    equity = initial_capital * exp(cumsum(port_ret));
    equity_tt = timetable(dates_returns, equity, ...
        'VariableNames', {params.name});

    peak = cummax(equity);
    drawdown = (equity - peak) ./ peak * 100;
    drawdown_tt = timetable(dates_returns, drawdown, ...
        'VariableNames', {params.name});

    %% 7) output allocazioni
    weights_tt = array2timetable(W, ...
        'RowTimes', dates_returns, ...
        'VariableNames', asset_names);
end
