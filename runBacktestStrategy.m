function [equity_tt, drawdown_tt, weights_tt] = runBacktestStrategy(params, prices_daily, prices_monthly, asset_names)
% Esegue il backtest per la strategia specificata in "params"
% Implementa:
%   - R    : momentum relativo (rank), equal-weight
%   - RA   : R + filtro momentum assoluto
%   - RAV  : R + filtro A + ranking volatilità
%   - RAVC : R + filtro A + ranking volatilità + ranking correlazione
%
% Pesi finali = equal-weight sui Top N asset selezionati

disp(['--- Esecuzione strategia: ', params.name, ' ---']);

%% Parametri
lookback = params.lookback_momentum; % mesi per momentum
topN = params.top_n_assets; % numero di asset da selezionare
LB_V = params.lookback_volatility; % mesi per vol
LB_C = params.lookback_correlation; % mesi per correlazione
n_assets = numel(asset_names);

%% 1) Momentum relativo 
momentum_matrix = nan(height(prices_monthly), n_assets);
for t = lookback+1:height(prices_monthly)
    momentum_matrix(t,:) = log(prices_monthly{t,:} ./ prices_monthly{t-lookback,:});
end
momentum_table = array2timetable(momentum_matrix, ...
    'RowTimes', prices_monthly.Date, ...
    'VariableNames', asset_names);

%% 2) Calcolo volatilità rolling dai rendimenti giornalieri
% Estrai solo colonne numeriche da prices_daily
numVars = varfun(@isnumeric, prices_daily, 'OutputFormat','uniform');
prezziD = prices_daily{:, numVars};
datesD = prices_daily.Date;

% Rendimenti giornalieri log
dailyR = diff(log(prezziD));
datesR = datesD(2:end);

n_assets = size(dailyR,2);
vol_matrix = nan(height(prices_monthly), n_assets);

% Loop sui mesi
for t = LB_V+1:height(prices_monthly)
    % Inizio/fine finestra basata su mesi
    startDate = dateshift(prices_monthly.Date(t-LB_V), 'start', 'month');
    endDate = dateshift(prices_monthly.Date(t), 'end', 'month');

    % Seleziona rendimenti giornalieri nella finestra
    mask = (datesR >= startDate & datesR <= endDate);
    window = dailyR(mask,:);

    % Calcola deviazione standard se ci sono dati validi
    if ~isempty(window)
        vol_matrix(t,:) = std(window, 0, 1, 'omitnan');
    end
end

% Tabella finale
vol_table = array2timetable(vol_matrix, ...
    'RowTimes', prices_monthly.Date, ...
    'VariableNames', asset_names);

%% 2) Calcolo correlazione rolling dai rendimenti giornalieri
corr_matrix = nan(height(prices_monthly), n_assets);
for t = LB_C+1:height(prices_monthly)
    % finestra di lookback di LB_C mesi (dal mese t-LB_C incluso a t incluso)
    startDate = dateshift(prices_monthly.Date(t-LB_C), 'start','month');
    endDate = dateshift(prices_monthly.Date(t), 'end','month');

    % seleziona rendimenti giornalieri dentro la finestra
    mask = (datesR >= startDate & datesR <= endDate);
    window = dailyR(mask,:);

    if size(window,1) > 2
        R = corr(window, 'Rows','pairwise'); % matrice NxN

        % viene tolta la diagonale (autocorrelazione = 1)
        R(1:size(R,1)+1:end) = NaN;

        % media delle correlazioni assolute per ogni asset
        avgCorr = mean(abs(R), 2, 'omitnan')';
        corr_matrix(t,:) = avgCorr; % score per tutti gli asset al mese t
    end
end

corr_table = array2timetable(corr_matrix, ...
    'RowTimes', prices_monthly.Date, ...
    'VariableNames', asset_names);

%% 4) Ranking momentum (per R/RA)
ranks_mom = tiedrank(momentum_table{:,:}')'; % rank per riga

%% 5) Selezione asset e costruzione pesi
weights = zeros(height(prices_monthly), n_assets);

% trova indice del risk-free già dentro ai dati
rf_idx = find(strcmp(asset_names, 'W1GI Index'));

for t = 1:height(prices_monthly)
    mom_t = momentum_table{t,:};
    vol_t = vol_table{t,:};
    corr_t = corr_table{t,:};
    abs_mask = mom_t > 0; % filtro A: momentum assoluto

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

        % allocazione con fallback nel risk-free
        if ~isempty(idx_sorted)
            n_valid = numel(idx_sorted);
            weights(t, idx_sorted) = 1/topN;
            if n_valid < topN
                weights(t, rf_idx) = (topN - n_valid) / topN;
            end
        else
            weights(t, rf_idx) = 1; % tutto nel risk free in caso di nessun asset selezionato
        end

    % --- Caso R / RA ---
    else
        [~, idx_sorted] = maxk(ranks_mom(t,:), topN);

        % filtro A
        if params.use_abs_momentum_filter
            idx_sorted = idx_sorted(abs_mask(idx_sorted));
        end

        % In R puro: no fallback, solo equal-weight sugli asset selezionati
        if ~isempty(idx_sorted)
            weights(t, idx_sorted) = 1/numel(idx_sorted);
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
