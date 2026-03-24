clc; 
clear all;

%% Suddivisione tra in e out of sample
load("Dataset_ETF_clean.mat");

% data finale IN SAMPLE
IS_end   = datetime(2006,12,31);
% data iniziale OUT OF SAMPLE
OOS_start = datetime(2007,1,1);
% data finale OUT OF SAMPLE
OOS_end   = datetime(2017,12,31);

% Definisco i periodi di backtest
backtest_periods = [
    struct('name', 'IN-SAMPLE', ...
           'start_date', prices_monthly.Date(1), ...
           'end_date', IS_end);
    struct('name', 'OUT-OF-SAMPLE', ...
           'start_date', OOS_start, ...
           'end_date', OOS_end);
    struct('name', 'FULL-SAMPLE', ...
           'start_date', prices_monthly.Date(1), ...
           'end_date', prices_monthly.Date(end))
];

%% Parametri comuni alle strategie
common_params.top_n_assets        = 7;
common_params.w_momentum          = 1;
common_params.lookback_momentum   = 4;

%% Definizione strategie
strategies_list = {
    % Benchmark: Equally Weighted
    struct('name','EW', ...
           'lookback_momentum',0, ...
           'lookback_volatility',0, ...
           'lookback_correlation',0, ...
           'w_volatility',0, ...
           'w_correlation',0, ...
           'use_abs_momentum_filter',false, ...
           'is_benchmark',true)

    % R: Momentum relativo, equal-weight
    struct('name','R', ...
           'lookback_momentum',4, ...
           'lookback_volatility',0, ...
           'lookback_correlation',0, ...
           'w_volatility',0, ...
           'w_correlation',0, ...
           'use_abs_momentum_filter',false, ...
           'is_benchmark',false)

    % RA: Momentum relativo + filtro assoluto
    struct('name','RA', ...
           'lookback_momentum',4, ...
           'lookback_volatility',0, ...
           'lookback_correlation',0, ...
           'w_volatility',0, ...
           'w_correlation',0, ...
           'use_abs_momentum_filter',true, ...
           'is_benchmark',false)

    % RAV: Momentum + filtro A + volatilità
    struct('name','RAV', ...
           'lookback_momentum',4, ...
           'lookback_volatility',4, ...
           'lookback_correlation',0, ...
           'w_volatility',0.5, ...
           'w_correlation',0, ...
           'use_abs_momentum_filter',true, ...
           'is_benchmark',false)

   % RAVC 4-4-4
    struct('name','RAVC 4-4-4', ...
           'lookback_momentum',4, ...
           'lookback_volatility',4, ...
           'lookback_correlation',4, ...
           'w_volatility',0.5, ...
           'w_correlation',0.5, ...
           'use_abs_momentum_filter',true, ...
           'is_benchmark',false)

    % RAVC 4-3-3
    struct('name','RAVC 4-3-3', ...
           'lookback_momentum',4, ...
           'lookback_volatility',3, ...
           'lookback_correlation',3, ...
           'w_volatility',0.5, ...
           'w_correlation',0.5, ...
           'use_abs_momentum_filter',true, ...
           'is_benchmark',false)

    % RAVC 5-5-5
    struct('name','RAVC 5-5-5', ...
           'lookback_momentum',5, ...
           'lookback_volatility',5, ...
           'lookback_correlation',5, ...
           'w_volatility',0.5, ...
           'w_correlation',0.5, ...
           'use_abs_momentum_filter',true, ...
           'is_benchmark',false)

    % RAVC 3-3-3
    struct('name','RAVC 3-3-3', ...
           'lookback_momentum',3, ...
           'lookback_volatility',3, ...
           'lookback_correlation',3, ...
           'w_volatility',0.5, ...
           'w_correlation',0.5, ...
           'use_abs_momentum_filter',true, ...
           'is_benchmark',false)
};
results = struct();

%% STEP 1: Benchmark Equally Weighted (EW)
initial_capital = 100000;

% Calcolo rendimenti mensili logaritmici degli asset
monthly_returns = log(prices_monthly{2:end,:} ./ prices_monthly{1:end-1,:});
dates_returns   = prices_monthly.Date(2:end);

monthly_returns_tt = array2timetable(monthly_returns, ...
    'RowTimes', dates_returns, ...
    'VariableNames', asset_names);

% Creazione matrice pesi EW (1/N sugli asset disponibili)
W = zeros(size(monthly_returns));
for t = 1:size(monthly_returns,1)
    available = ~isnan(monthly_returns(t,:));
    n_av = sum(available);
    if n_av > 0
        W(t,available) = 1/n_av;
    end
end

% Shift dei pesi (usa i pesi del mese t per investire al mese t+1)
W_shift = [zeros(1,size(W,2)); W(1:end-1,:)];

% Numero di mesi di lookback
lookback = common_params.lookback_momentum;
W_shift(1:lookback, :) = 0;   % nessuna allocazione fino al quarto mese

% Ritorni del portafoglio EW
port_ret = nansum(W_shift .* monthly_returns, 2);

% Equity line (capitalizzazione additiva)
benchmark_equity = initial_capital * exp(cumsum(port_ret));

benchmark_tt = timetable(dates_returns, benchmark_equity, ...
    'VariableNames', {'Benchmark_EW'});

% Drawdown
peak = cummax(benchmark_equity);
dd = (benchmark_equity - peak) ./ peak * 100;

benchmark_dd_tt = timetable(dates_returns, dd, ...
    'VariableNames', {'Benchmark_EW'});

% Salvo nei results
results.Benchmark.equity   = benchmark_tt;
results.Benchmark.drawdown = benchmark_dd_tt;
results.Benchmark.allocation = W_shift;

%% STEP 1 bis: Strategia Moving Average (MA(1,12))
initial_capital = 100000;
LB = 12; % finestra di lookback 12 mesi

% === Estrazione dati di base ===
prices  = prices_monthly{:, 2:end};
dates   = prices_monthly.Date;
returns = log(prices(2:end,:) ./ prices(1:end-1,:)); % rendimenti mensili log
dates_returns = dates(2:end);

% === Identifica colonna del risk-free proxy (W1GI) ===
rf_idx = find(strcmpi(asset_names, 'W1GI Index'));
rf = returns(:, rf_idx);  % serie W1GI

% === Calcolo media mobile a 12 mesi (shiftata per evitare look-ahead) ===
ma12 = movmean(prices, [LB-1 0], 'omitnan');
ma12 = [nan(LB, size(prices,2)); ma12(1:end-LB,:)]; % shift di 1 mese ex-ante

% === Segnale Moving Average (1 se prezzo > MA12) ===
ma_signal = prices > ma12;

% === Inizializza pesi e rendimento portafoglio ===
W_MA = zeros(size(returns));
port_ret_MA = zeros(size(returns,1),1);

for t = 1:size(returns,1)
    % ---- Segnale ex-ante: usa informazione fino al mese precedente ----
    if t > 1
        valid = find(ma_signal(t-1,:)); % asset sopra la MA nel mese precedente
    else
        valid = [];
    end
    n_valid = numel(valid);

    % ---- Equal weight tra gli asset sopra MA ----
    if n_valid > 0
        W_MA(t, valid) = 1 / n_valid;
    end

    % ---- Aggiungi componente cash (W1GI) per gli asset sotto MA ----
    if n_valid < size(returns,2)
        W_MA(t, rf_idx) = W_MA(t, rf_idx) + (size(returns,2) - n_valid) / size(returns,2);
    end

    % ---- Normalizza i pesi (devono sempre sommare a 1) ----
    if sum(W_MA(t,:),'omitnan') > 0
        W_MA(t,:) = W_MA(t,:) ./ sum(W_MA(t,:),'omitnan');
    end

    % ---- Calcolo rendimento logaritmico corretto del portafoglio ----
    valid_w = W_MA(t,:) > 0 & isfinite(returns(t,:));
    if any(valid_w)
        port_ret_MA(t) = log(sum(W_MA(t,valid_w) .* exp(returns(t,valid_w))));
    else
        port_ret_MA(t) = 0;
    end
end

% === Shift dei pesi per evitare look-ahead (usa pesi di t per investire in t+1) ===
W_MA_shift = [zeros(1,size(W_MA,2)); W_MA(1:end-1,:)];
W_MA_shift(1:LB,:) = 0;  % nessuna allocazione nei primi 12 mesi

% === Equity line (capitalizzazione additiva dei log returns) ===
equity_MA = initial_capital * exp(cumsum(port_ret_MA));

% === Drawdown ===
peak_MA = cummax(equity_MA);
dd_MA = (equity_MA - peak_MA) ./ peak_MA * 100;

% === Salvataggio nei results ===
fld = matlab.lang.makeValidName('MA');
results.(fld).equity   = timetable(dates_returns, equity_MA, 'VariableNames', {'Equity_MA'});
results.(fld).drawdown = timetable(dates_returns, dd_MA, 'VariableNames', {'Drawdown_MA'});
results.(fld).allocation = W_MA_shift;
%% STEP 2: Backtest delle altre strategie (R, RA, RAV, RAVC, …)
for s = 1:numel(strategies_list)
    params = strategies_list{s};
    % salta EW (benchmark già calcolato sopra)
    if params.is_benchmark
        continue;
    end

    % Aggiungo parametri comuni
    params.top_n_assets      = common_params.top_n_assets;
    params.w_momentum        = common_params.w_momentum;

    % richiama la funzione runBacktestStrategy
    fld = matlab.lang.makeValidName(params.name);
    [equity_tt, drawdown_tt, weights_tt] = runBacktestStrategy( ...
        params, prices_daily, prices_monthly, asset_names);

    % salvo i risultati
    results.(fld).equity     = equity_tt;
    results.(fld).drawdown   = drawdown_tt;
    results.(fld).allocation = weights_tt;
end

%% PLOT CONFRONTO STRATEGIE per ciascun periodo
strategy_names = fieldnames(results);

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);

    % --- PLOT EQUITY ---
    figure('Name', sprintf('Equity Confronto Strategie (%s)', period.name), ...
        'NumberTitle','off','Color','w');
    hold on;

    for s = 1:numel(strategy_names)
        name = strategy_names{s};

        if ~isfield(results.(name), 'equity')
            continue;
        end

        eq = results.(name).equity;
        varName = eq.Properties.VariableNames{1};

        % Filtra il sottoperiodo
        mask = (eq.dates_returns >= period.start_date) & (eq.dates_returns <= period.end_date);
        eq_period = eq(mask,:);

        if isempty(eq_period)
            continue;
        end

        % Estraggo i valori numerici
        eq_values = eq_period.(varName);

        % Rinormalizzo a capitale iniziale
        eq_values = 100000 * eq_values / eq_values(1);

        % Plot
        plot(eq_period.dates_returns, eq_values, 'LineWidth', 1.5);
    end

    grid on;
    set(gca,'YScale','log');
    xlabel('Data'); ylabel('Equity (scala logaritmica)');
    title(sprintf('Equity Line - Confronto Strategie (%s)', period.name));
    legend(strategy_names, 'Location','northwest');
    hold off;


    % --- PLOT DRAWDOWN ---
    figure('Name', sprintf('Drawdown Confronto Strategie (%s)', period.name), ...
        'NumberTitle','off','Color','w');
    hold on;

    for s = 1:numel(strategy_names)
        name = strategy_names{s};

        if ~isfield(results.(name), 'equity')
            continue;
        end

        eq = results.(name).equity;
        varName = eq.Properties.VariableNames{1};

        mask = (eq.dates_returns >= period.start_date) & (eq.dates_returns <= period.end_date);
        eq_period = eq(mask,:);

        if isempty(eq_period)
            continue;
        end

        eq_values = eq_period.(varName);
        eq_values = 100000 * eq_values / eq_values(1);

        % Calcolo drawdown
        peak_eq = cummax(eq_values);
        dd_values = (eq_values - peak_eq) ./ peak_eq * 100;

        % Plot
        plot(eq_period.dates_returns, dd_values, 'LineWidth', 1.5);
    end

    grid on;
    xlabel('Data'); ylabel('Drawdown (%)');
    title(sprintf('Drawdown - Confronto Strategie (%s)', period.name));
    legend(strategy_names, 'Location','southwest');
    hold off;
end


%% PLOT CORRELAZIONE TRA STRATEGIE (per IS, OOS, FS)
strategy_names = fieldnames(results);

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);

    % === Costruzione tabella rendimenti mensili delle strategie ===
    strategy_returns = table();  % inizializzo una table vuota

    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        eq = results.(name).equity;

        % Filtra il sottoperiodo
        mask = (eq.dates_returns >= period.start_date & eq.dates_returns <= period.end_date);
        eq_period = eq(mask,:);

        % Rendimenti log mensili della strategia
        strat_rets = [NaN; diff(log(eq_period{:,1}))];

        % Aggiungo la colonna alla table con il nome della strategia
        strategy_returns.(name) = strat_rets;
    end

    % Aggiungo la colonna delle date (una sola volta, da qualsiasi equity)
    strategy_returns.Date = eq_period.dates_returns;
    strategy_returns = movevars(strategy_returns, 'Date', 'Before', 1);

    strategy_returns_double = strategy_returns{:, 2:end};
    % matrice di correlazione tra strategie
    R = corr(strategy_returns_double, 'Rows','pairwise');

    % range adattato ai valori osservati (con margine)
    minR = floor(min(R(:))*100)/100;
    maxR = ceil(max(R(:))*100)/100;

    % heatmap
    figure('Name', sprintf('Correlazione Strategie (%s)', period.name), ...
           'NumberTitle','off','Color','w');
    h = heatmap(strategy_names, strategy_names, R, ...
                'Colormap', turbo, ...
                'ColorLimits', [minR maxR]);

    % etichette e titolo
    h.Title = sprintf('Matrice di correlazione tra strategie - %s', period.name);
    h.XLabel = 'Strategie';
    h.YLabel = 'Strategie';

    % valori numerici nelle celle
    h.CellLabelFormat = '%.2f';
end  
%% CALCOLO METRICHE DI PERFORMANCE (Sharpe, Sortino, ecc.)
dates_all = monthly_returns_tt.Time;             % vettore date mensili
rf_full = monthly_returns_tt{:,'W1G1 Index'};             % rendimenti mensili risk-free

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);

    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        eq = results.(name).equity;

        % === Filtro temporale basato sulle DATE ===
        mask = (dates_all >= period.start_date & dates_all <= period.end_date);

        % === Filtra tutte le serie sullo stesso intervallo ===
        rets = strategy_returns.(name)(mask);
        r_benchmark = port_ret(mask);
        rf = rf_full(mask);                      % <-- nuovo: risk-free allineato

        % === Calcolo metriche ===
        metrics = evaluateStrategy(rets, r_benchmark, rf);

        % === Salvataggio risultati ===
        period_field = matlab.lang.makeValidName(period.name);
        results.(name).metrics.(period_field) = metrics;
    end
end

%% CALCOLO METRICA OMEGA (OPR) - confronto rispetto al benchmark
epsv = 1e-8;  % tolleranza numerica

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);
    period_field = matlab.lang.makeValidName(period.name);

    % === metriche del benchmark ===
    if isfield(results, 'Benchmark') && isfield(results.Benchmark.metrics, period_field)
        m_bench = results.Benchmark.metrics.(period_field);
    else
        warning('Benchmark non trovato per %s', period.name);
        continue;
    end

    S_b = m_bench.SortinoMod;
    C_b = m_bench.Calmar;
    R_b = m_bench.Robust;

    % === loop su tutte le strategie ===
    for s = 1:numel(strategy_names)
        name = strategy_names{s};

        % salta il benchmark stesso
        if strcmpi(name, 'Benchmark')
            results.(name).metrics.(period_field).Omega = 0;
            continue;
        end

        m = results.(name).metrics.(period_field);

        % metriche della strategia
        S_i = m.SortinoMod;
        C_i = m.Calmar;
        R_i = m.Robust;

        % variazioni relative (rispetto al benchmark)
        relS = (S_i - S_b) / S_b;
        relC = (C_i - C_b) / C_b;
        relR = (R_i - R_b) / R_b;

        
        % media delle tre variazioni
        Omega_final = relS + relC + relR / 3;

        % salva nella struttura results
        results.(name).metrics.(period_field).Omega = Omega_final;
    end
end

%% CREAZIONE TABELLE DI CONFRONTO METRICHE (inclusa OMEGA)
comparison_tables = struct();

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);
    period_field = matlab.lang.makeValidName(period.name);

    strat_names = {};
    cagr = []; sharpe = []; sortino = []; sortino_mod = [];
    calmar = []; robust = []; omega = [];
    vol = []; maxdd = []; var5 = []; es5 = [];
    bestm = []; worstm = [];
    profm = []; roll1y = []; roll5y = []; roll10y = [];
    upcorr = []; downcorr = []; negcorr = []; poscorr = []; te = [];

    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        strat_names{end+1,1} = name;

        m = results.(name).metrics.(period_field);

        cagr(end+1,1)    = m.CAGR;
        vol(end+1,1)     = m.AnnualizedVol;
        sharpe(end+1,1)  = m.Sharpe;
        sortino(end+1,1) = m.Sortino;
        sortino_mod(end+1,1) = m.SortinoMod;   
        calmar(end+1,1)  = m.Calmar;
        robust(end+1,1)  = m.Robust;           
        omega(end+1,1)   = m.Omega;           
        maxdd(end+1,1)   = m.WorstDrawdown;
        var5(end+1,1)    = m.VaR_5pct;
        es5(end+1,1)     = m.ES_5pct;
        bestm(end+1,1)   = m.BestMonth;
        worstm(end+1,1)  = m.WorstMonth;
        profm(end+1,1)   = m.ProfitableMonths;
        roll1y(end+1,1)  = m.Rolling1YWinPct;
        roll5y(end+1,1)  = m.Rolling5YWinPct;
        roll10y(end+1,1) = m.Rolling10YWinPct;
        upcorr(end+1,1)  = m.UpCorrPct;
        downcorr(end+1,1)= m.DownCorrPct;
        negcorr(end+1,1) = m.NegativeCorrPct;
        poscorr(end+1,1) = m.PositiveCorrPct;
        te(end+1,1)      = m.TrackingErrorPct;
    end

    % --- Tabella riassuntiva con Omega
    results_summary.(period_field) = table( ...
        cagr, vol, sharpe, sortino, sortino_mod, calmar, robust, omega, ...
        maxdd, var5, es5, bestm, worstm, profm, ...
        roll1y, roll5y, roll10y, upcorr, downcorr, negcorr, poscorr, te, ...
        'VariableNames', {'CAGR','Vol','Sharpe','Sortino','SortinoMod','Calmar','Robust','Omega', ...
                          'MaxDD','VaR5%','ES5%','BestM','WorstM','ProfM', ...
                          'Roll1Y','Roll5Y','Roll10Y','Up%','Down%','NegCorr%','PosCorr%','TE%'}, ...
        'RowNames', strat_names);

    % --- Tabella compatta per confronto
    T = table( ...
        cagr, vol, sharpe, sortino, sortino_mod, calmar, robust, omega, ...
        maxdd, var5, es5, bestm, worstm, profm, ...
        roll1y, roll5y, roll10y, ...
        upcorr, downcorr, negcorr, poscorr, te, ...
        'RowNames', strat_names);

    T.Properties.VariableNames = { ...
        'CAGR','Volatility','Sharpe','Sortino','SortinoMod','Calmar','Validity','Omega', ...
        'MaxDD','VaR5pct','ES5pct','BestMonth','WorstMonth', ...
        'ProfitableMonths','Roll1YWin','Roll5YWin','Roll10YWin', ...
        'UpPct','DownPct','NegCorrPct','PosCorrPct','TrackingErrorPct'};

    comparison_tables.(period_field) = T;
end
%% PLOT ROLLING 5-YEAR RETURNS per ciascun periodo
window = 60; % 5 anni = 60 mesi

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);
    period_field = matlab.lang.makeValidName(period.name);

    figure('Name', sprintf('Rolling 5Y Returns (%s)', period.name), ...
        'NumberTitle','off','Color','w'); 
    hold on;

    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        eq = results.(name).equity;

        % filtra sottoperiodo
        mask = (eq.dates_returns >= period.start_date & eq.dates_returns <= period.end_date);
        eq_period = eq(mask,:);

        % calcolo rolling CAGR a 5 anni
        eq_vals = eq_period{:,1};
        dates   = eq_period.dates_returns;
        roll_ret = nan(size(eq_vals));

        for t = window:length(eq_vals)
            V_start = eq_vals(t-window+1);
            V_end   = eq_vals(t);
            roll_ret(t) = (V_end/V_start)^(12/window) - 1;  % CAGR annuo su 5 anni
        end

        % plot
        plot(dates, roll_ret*100, 'LineWidth', 1.5);
    end

    grid on;
    xlabel('Data'); ylabel('Rolling 5Y Return (%)');
    title(sprintf('Rolling 5-Year Annualized Returns - %s', period.name));
    legend(strategy_names, 'Location','best');
    hold off;
end

%% PLOT METRICHE: Rendimento vs Rischio (con colori fissi)
strategy_names = fieldnames(results);
num_strat = numel(strategy_names);

% Palette di colori (1 colore per strategia, sempre lo stesso)
colors = lines(num_strat);

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);
    period_field = matlab.lang.makeValidName(period.name);

    T = comparison_tables.(period_field);
    strat_names = T.Properties.RowNames;

    % --- Figure RENDIMENTO ---
    figure('Name', sprintf('Metriche di RENDIMENTO (%s)', period.name), ...
        'NumberTitle','off','Color','w');

    % CAGR
    subplot(3,2,1);
    b = bar(categorical(strat_names), T.CAGR); 
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('CAGR'); ylabel('%'); grid on;

    % Sharpe
    subplot(3,2,2);
    b = bar(categorical(strat_names), T.Sharpe);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Sharpe Ratio'); grid on;

    % Sortino
    subplot(3,2,3);
    b = bar(categorical(strat_names), T.Sortino);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Sortino Ratio'); grid on;

    % Rolling 1Y Win
    subplot(3,2,5);
    b = bar(categorical(strat_names), T.Roll1YWin);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Rolling 1Y Win %'); grid on;

    % Calmar Ratio
    subplot(3,2,4);
    b = bar(categorical(strat_names), T.Calmar);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Calmar Ratio'); grid on;

    % Omega
    subplot(3,2,6);
    b = bar(categorical(strat_names), T.Omega);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Omega Portfolio Rating'); grid on;

    sgtitle(sprintf('Metriche di Rendimento - %s', period.name));

    % --- Figure RISCHIO ---
    figure('Name', sprintf('Metriche di RISCHIO (%s)', period.name), ...
        'NumberTitle','off','Color','w');

    % Volatilità
    subplot(3,2,1);
    b = bar(categorical(strat_names), T.Volatility);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Volatilità Annua'); ylabel('%'); grid on;

    % Worst Drawdown
    subplot(3,2,2);
    b = bar(categorical(strat_names), T.MaxDD);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Worst Drawdown'); ylabel('%'); grid on;

    % Best Month
    subplot(3,2,3);
    b = bar(categorical(strat_names), T.BestMonth);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Best Month'); grid on;

    % Worst Month
    subplot(3,2,4);
    b = bar(categorical(strat_names), T.WorstMonth);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Worst Month'); grid on;

    % Var 5%
    subplot(3,2,5);
    b = bar(categorical(strat_names), T.VaR5pct);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('VaR 5%'); grid on;

    % Expected Shortfall
    subplot(3,2,6);
    b = bar(categorical(strat_names), T.ES5pct);
    b.FaceColor = 'flat';
    for k = 1:numel(strat_names), b.CData(k,:) = colors(k,:); end
    title('Expected Shortfall 5'); grid on;

    sgtitle(sprintf('Metriche di Rischio - %s', period.name));
end
%% === Identificazione cicli di mercato (Bull/Bear) ===
% Usiamo come riferimento l'equity del Benchmark (EW)
ref = results.Benchmark.equity;
dates = ref.dates_returns;
vals  = ref{:,1};

% Calcolo drawdown del benchmark
peak = cummax(vals);
dd = (vals - peak) ./ peak;

% Regola: Bear se drawdown <= -20%, altrimenti Bull
isBear = dd <= -0.20;
isBull = ~isBear;

% Segmentazione dei cicli
cycles = {};
current_state = isBull(1);
start_idx = 1;

for t = 2:length(vals)
    if isBull(t) ~= current_state
        % chiudi ciclo precedente
        cycles{end+1} = struct( ...
            'state', ternary(current_state,'BULL','BEAR'), ...
            'start_date', dates(start_idx), ...
            'end_date', dates(t-1));
        % apri nuovo ciclo
        start_idx = t;
        current_state = isBull(t);
    end
end

% aggiungi ultimo ciclo
cycles{end+1} = struct( ...
    'state', ternary(current_state,'BULL','BEAR'), ...
    'start_date', dates(start_idx), ...
    'end_date', dates(end));

for c = 1:numel(cycles)
    fprintf('%s: %s → %s\n', ...
        cycles{c}.state, string(cycles{c}.start_date), string(cycles{c}.end_date));
end

%% === Analisi delle strategie per ciclo ===
strategy_names = fieldnames(results);
cycle_perf = struct();

for c = 1:numel(cycles)
    cyc = cycles{c};
    cycle_perf.(cyc.state)(c).name = sprintf('%s_%d',cyc.state,c);
    cycle_perf.(cyc.state)(c).start = cyc.start_date;
    cycle_perf.(cyc.state)(c).end   = cyc.end_date;

    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        eq = results.(name).equity;

        % filtro periodo ciclo
        mask = (eq.dates_returns >= cyc.start_date & eq.dates_returns <= cyc.end_date);
        eq_period = eq(mask,:);

        if isempty(eq_period), continue; end

        % rendimento cumulato nel ciclo
        ret_cycle = eq_period{end,1} / eq_period{1,1} - 1;

        cycle_perf.(cyc.state)(c).(name) = ret_cycle;
    end
end

%% === Plot Market Cycle Performance (flat style) ===
figure('Name','Market Cycle Performance','Color','w','Position',[100 100 900 300]); % grafico più basso
hold on;
barData = [];
labels = {};

for c = 1:numel(cycles)
    cyc = cycles{c};
    vals = [];
    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        if isfield(cycle_perf.(cyc.state)(c), name)
            vals(end+1) = cycle_perf.(cyc.state)(c).(name)*100; % in %
        else
            vals(end+1) = NaN;
        end
    end
    barData = [barData; vals];
    labels{end+1} = sprintf('%s: %s-%s', ...
        cyc.state, datestr(cyc.start_date,'mm/yyyy'), datestr(cyc.end_date,'mm/yyyy'));
end

% === Istogramma compatto e piatto ===
b = bar(barData, 'grouped', 'BarWidth', 0.9); % barre attaccate (no spazio)
for i = 1:numel(b)
    b(i).EdgeColor = 'none'; % look pulito
end

legend(strategy_names, 'Location', 'best');
xticklabels(labels);
xtickangle(30);
ylabel('Return (%)');
title('Market Cycle Performance');
grid on;
box on;

% === Appiattisci sull'asse Y ===
axis tight;                     % margini stretti
ax = gca;
ax.PlotBoxAspectRatio = [3 0.6 1]; % [larghezza, altezza, profondità]
ylim([-150 450]);                % stesso range visivo del tuo esempio

%% === Funzione di supporto ternary ===
function out = ternary(cond,a,b)
if cond, out=a; else, out=b; end
end
%% stress events analysis
events = {
    struct('name','October 87 Crash','start',datetime(1987,10,1),'end',datetime(1987,12,31));
    struct('name','Asian Crisis','start',datetime(1997,8,1),'end',datetime(1998,8,31));
    struct('name','LTCM/Russian Default','start',datetime(1998,8,1),'end',datetime(1998,9,30));
    struct('name','NASDAQ Run Up','start',datetime(1999,1,1),'end',datetime(2000,3,31));
    struct('name','NASDAQ Melt Down','start',datetime(2000,4,1),'end',datetime(2001,9,30));
    struct('name','Credit Crunch','start',datetime(2008,9,1),'end',datetime(2009,2,28));
    struct('name','European Sovereign Debt Crisis','start',datetime(2010,1,1),'end',datetime(2012,12,31));
};

strategy_names = fieldnames(results);

%% === Calcolo Performance negli Eventi ===
event_perf = nan(numel(events), numel(strategy_names));

for e = 1:numel(events)
    ev = events{e};
    for s = 1:numel(strategy_names)
        name = strategy_names{s};
        eq = results.(name).equity;

        mask = (eq.dates_returns >= ev.start & eq.dates_returns <= ev.end);
        eq_event = eq(mask,:);

        if isempty(eq_event)
            event_perf(e,s) = NaN;
        else
            ret_event = eq_event{end,1} / eq_event{1,1} - 1;
            event_perf(e,s) = ret_event * 100; % in %
        end
    end
end
figure('Name','Short-Term Event Stress Tests','Color','w');
b = bar(event_perf,'grouped');
legend(strategy_names,'Location','bestoutside');
xticklabels(cellfun(@(x)x.name, events,'UniformOutput',false));
xtickangle(30);
ylabel('Return (%)');
title('Short-Term Event Stress Tests');
grid on;
% === Stile compatto e piatto ===
for i = 1:numel(b)
    b(i).BarWidth = 0.9;     % barre attaccate
    b(i).EdgeColor = 'none'; % look pulito
end

axis tight;
ax = gca;

% Limiti Y dinamici con margine per non troncare i valori
yLimits = [min(event_perf(:)) max(event_perf(:))];
if all(isfinite(yLimits))
    margin = 0.1 * range(yLimits);
    ylim([yLimits(1)-margin, yLimits(2)+margin]);
end

% Appiattisci il grafico
ax.PlotBoxAspectRatio = [3 0.55 1];  % più largo e basso
ax.Position(4) = 0.25;               % riduce altezza visiva
box on;
%% ============================================
%  DRAWDOWN ANALYSIS (aggregazione + grafico)
%  ============================================

% Lista strategie salvate nei results
strategies = fieldnames(results);

% Definizione categorie di analisi
categories = {'MaxDD','Monthly','DD12','DD36'};

% Preallocazione matrice risultati
drawdown_data = nan(numel(categories), numel(strategies));

%% === 1) Calcolo metriche sintetiche per ogni strategia ===
for i = 1:numel(strategies)
    s = strategies{i};

    % Estraggo serie drawdown
    dd_tt = results.(s).drawdown;
    
    dd = dd_tt{:,1};  % drawdown in percentuale
    dd(isnan(dd)) = [];

    % --- 1. MaxDD ---
    MaxDD = min(dd);

    % --- 2. Monthly average drawdown ---
    Monthly = mean(dd);

    % --- 3. 12-Month worst cumulative drawdown ---
    window12 = movmean(dd, 12, 'omitnan');
    DD12 = min(window12);

    % --- 4. 36-Month worst cumulative drawdown ---
    window36 = movmean(dd, 36, 'omitnan');
    DD36 = min(window36);

    % Salvo nel struct results
    results.(s).drawdowns = struct( ...
        'MaxDD', MaxDD, ...
        'Monthly', Monthly, ...
        'DD12', DD12, ...
        'DD36', DD36);

    % Popolo matrice per il grafico
    drawdown_data(:,i) = [MaxDD, Monthly, DD12, DD36];
end

%% === 2) Creazione del grafico ===
figure('Color','w','Name','Drawdown Analysis');
b = bar(drawdown_data, 'grouped');
hold on;

% Palette colori
cmap = lines(numel(strategies));
for i = 1:numel(b)
    b(i).FaceColor = cmap(i,:);
    b(i).EdgeColor = 'none';
end

% Etichette e stile
set(gca,'XTickLabel',{'MaxDD','Monthly','12-Month','36-Month'});
xtickangle(30);
ylabel('Drawdown / Return (%)');
title('Drawdown Analysis');
grid on;

legend(strategies,'Location','bestoutside');

% Scala verticale coerente al grafico esempio
ylim([-30 5]);
yticks(-50:10:20);
yticklabels(arrayfun(@(x)sprintf('%d%%',x),-50:10:20,'UniformOutput',false));

for i = 1:numel(b)
    b(i).BarWidth = 0.7;  % barre più piatte
end

%% === GRAFICI DELLA DISTRIBUZIONE DEI RENDIMENTI (VaR & ES) PER OGNI PERIODO ===

for p = 1:numel(backtest_periods)
    period = backtest_periods(p);
    
    % === Normalizzazione del nome del periodo ===
    normalized_name = upper(regexprep(period.name, '[-_ ]', '')); % rimuove -, _, e spazi
    
    switch normalized_name
        case 'INSAMPLE'
            period_field = 'IN_SAMPLE';
        case 'OUTOFSAMPLE'
            period_field = 'OUT_OF_SAMPLE';
        case 'FULLSAMPLE'
            period_field = 'FULL_SAMPLE';
        otherwise
            warning('Periodo "%s" non riconosciuto.', period.name);
            continue;
    end
    
    % === Layout figure ===
    num_strat = numel(strategy_names);
    rows = ceil(sqrt(num_strat));
    cols = ceil(num_strat / rows);
    
    figure('Color','w', 'Name', ['Distribuzioni Rendimenti - ' period_field], ...
           'Position',[100 100 1200 800]);
    
    % === Ciclo sulle strategie ===
    for s = 1:num_strat
        name = strategy_names{s};
        
        % === Recupera rendimenti e metriche ===
        rets_full = strategy_returns.(name);
        mask = (monthly_returns_tt.Time >= period.start_date & ...
                monthly_returns_tt.Time <= period.end_date);
        rets = rets_full(mask);
        
        if isempty(rets)
            continue; % salta se non ci sono dati per il periodo
        end
        
        % === Recupera VaR ed ES ===
        m = results.(name).metrics.(period_field);
        VaR_5 = m.VaR_5pct;
        ES_5  = m.ES_5pct;
        
        % === Stima densità con kernel ===
        [f_pdf, x_pdf] = ksdensity(rets, 'NumPoints', 200);
        [x_pdf, sort_idx] = sort(x_pdf, 'ascend');
        f_pdf = f_pdf(sort_idx);
        
        % === Colori ===
        color_main = [0.2 0.6 0.9];   % blu chiaro
        color_tail = [1 0.4 0.4];     % rosso chiaro
        color_VaR  = [0.9 0.1 0.1];   % rosso scuro per VaR
        color_ES   = [0.45 0.1 0.85]; % viola per ES
        
        % === Subplot ===
        subplot(rows, cols, s);
        hold on; box on; grid on;
        set(gca, 'XDir', 'normal'); % forza asse corretto
        
        % === Area distribuzione intera ===
        area(x_pdf, f_pdf, 'FaceColor', color_main, 'FaceAlpha', 0.4, 'EdgeColor', 'none');
        
        % === Area coda sotto il VaR ===
        idx_tail = x_pdf <= VaR_5;
        area(x_pdf(idx_tail), f_pdf(idx_tail), 'FaceColor', color_tail, 'FaceAlpha', 0.6, 'EdgeColor', 'none');
        
        % === Linea densità sopra l'area ===
        plot(x_pdf, f_pdf, 'Color', [0 0 0 0.5], 'LineWidth', 1.2);
        
        % === Linee verticali VaR / ES ===
        yl = ylim;
        plot([VaR_5 VaR_5], yl, 'Color', color_VaR, 'LineWidth', 2);
        plot([ES_5 ES_5], yl, 'Color', color_ES, 'LineStyle', '--', 'LineWidth', 2);
        
        % === Marker alla base ===
        plot(VaR_5, yl(1), 'v', 'Color', color_VaR, 'MarkerFaceColor', color_VaR, 'MarkerSize', 5);
        plot(ES_5,  yl(1), 'v', 'Color', color_ES, 'MarkerFaceColor', color_ES, 'MarkerSize', 5);
        
        % === Etichette ===
        text(VaR_5, yl(2)*0.85, sprintf('VaR: %.2f%%', VaR_5*100), ...
             'HorizontalAlignment', 'right', 'FontSize', 8, 'Color', color_VaR);
        text(ES_5, yl(2)*0.7, sprintf('ES: %.2f%%', ES_5*100), ...
             'HorizontalAlignment', 'right', 'FontSize', 8, 'Color', color_ES, 'FontAngle', 'italic');
        
        % === Asse e titolo ===
        xlabel('Rendimento mensile');
        ylabel('Densità stimata');
        title(name, 'Interpreter', 'none', 'FontWeight', 'bold', 'FontSize', 9);
        
        % === Legenda ===
        legend({'Distribuzione', 'Coda < VaR', 'Densità', 'VaR 5%', 'ES 5%'}, ...
            'Location', 'northeast', 'FontSize', 7, 'Box', 'off');
        
        hold off;
    end
    
    % === Titolo generale ===
    sgtitle(sprintf('Distribuzione dei rendimenti mensili (%s)\nVaR 5%% ed Expected Shortfall', ...
        strrep(period_field, '_', ' ')), 'FontWeight', 'bold');
    
    % === Salvataggio ===
    exportgraphics(gcf, sprintf('VaR_ES_Distribution_%s.png', period_field), 'Resolution', 300);
end

%% =====================================================
%  TABELLA DEI RENDIMENTI ANNUALI (%) PER OGNI STRATEGIA
%  =====================================================
strategy_names = fieldnames(results);

% Lista di tutti gli anni presenti (dal primo all'ultimo mese dei dati)
all_dates = monthly_returns_tt.Time;
years = unique(year(all_dates));

% Preallocazione cella per i valori testuali con '%'
annual_return_cell = cell(length(years), numel(strategy_names));

for s = 1:numel(strategy_names)
    strat_name = strategy_names{s};
    eq = results.(strat_name).equity;
    
    % === Calcolo rendimenti mensili logaritmici ===
    eq_vals = eq{:,1};
    eq_dates = eq.dates_returns;
    monthly_rets = [NaN; diff(log(eq_vals))];
    
    % === Calcolo rendimento annuale composto ===
    for y = 1:length(years)
        year_mask = year(eq_dates) == years(y);
        r_year = monthly_rets(year_mask);
        r_year = r_year(isfinite(r_year));
        
        if ~isempty(r_year)
            annual_return = exp(sum(r_year)) - 1;  % rendimento composto
            annual_return_cell{y, s} = sprintf('%.2f%%', annual_return * 100);
        else
            annual_return_cell{y, s} = 'N/A';
        end
    end
end

% === Creazione della tabella finale ===
annual_return_table = cell2table(annual_return_cell, ...
    'RowNames', cellstr(string(years)), ...
    'VariableNames', strategy_names);

%% (Opzionale) Salva la tabella come CSV
writetable(annual_return_table, 'Annual_Returns_Per_Strategy.csv', 'WriteRowNames', true);

