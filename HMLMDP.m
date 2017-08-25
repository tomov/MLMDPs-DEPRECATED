classdef HMLMDP

    properties (Constant = true)
        subtask_symbol = 'S';
        goal_symbol = '$'; % we use absorbing_symbol to distinguish all boundary states, however not all of them are goals in the actual task.

        R_goal = 3; % the actual reward for completing the task; shouldn't matter much (0 should work too); interacts w/ rt -> has to be > 0 o/w the rt's of undersirable St's are 0 and compete with it, esp when X passes through them -> it is much better to go into the St state than to lose a few more -1's to get to a cheap goal state; but if too high -> never enter St states...
        R_St = -5; % reward for St states to encourage entering them every now and then; determines at(:,:); too high -> keeps entering St state; too low -> never enters St state... TODO

        rt_coef = 20; % coefficient by which to scale rt when recomputing weights on current level based on higher-level solution
    end

    properties (Access = public)
        M = []; % current level (augmented) MLMDP
        next = []; % next level HMLMDP #recursion
    end

    methods 
        function self = HMLMDP(arg)
            if isa(arg, 'HMLMDP')
                % We're at the next level of the hierarchy
                %
                M1 = arg.M; 
                assert(isa(M1, 'AMLMDP'));

                Ni = numel(M1.St); % St from lower level == I on current level

                % use a fake map to create the current level MLMDP
                % it sets up stuff, including S, I, R and Qb
                %
                M = MLMDP(repmat('0', [1 Ni]));

                % Set up states
                %
                Nb = Ni;
                N = Ni + Nb;
                assert(isequal(M.I, 1 : Ni));
                assert(isequal(M.B, Ni + 1 : 2 * Ni));

                % Set up passive transition dynamics P according to lower level
                %
                M1_Ni = numel(M1.I);
                M1_Pi = M1.P(M1.I, M1.I);
                M1_Pt = M1.P(M1.St, M1.I);
                Pi = M1_Pt * inv(eye(M1_Ni) - M1_Pi) * M1_Pt'; % I --> I from low-level dynamics, Eq 8 from Saxe et al (2017)
                %Pb = M1.Pb * inv(eye(M1.Ni) - M1.Pi) * M1.Pt'; Eq 9 from Saxe et al (2017)
                Pi(logical(eye(Ni))) = 0; % TODO P(s|s) = 0; otherwise too high
                Pb = eye(Ni) * LMDP.P_I_to_B; % small prob I --> B
                assert(size(M.P, 1) == N);
                assert(size(M.P, 2) == N);
                M.P(M.I, M.I) = Pi;
                M.P(M.B, M.I) = Pb;
                M.P = M.P ./ sum(M.P, 1); % normalize
                M.P(isnan(M.P)) = 0;

                self.M = M;
            else
                % We're at the lowest level of the hierarchy
                %
                map = arg;
                assert(ischar(map));

                subtask_inds = find(map == HMLMDP.subtask_symbol)';
                map(subtask_inds) = LMDP.empty_symbol; % even though AMLMDP's are aware of subtask states, they don't want them in the map b/c they just pass it down to the MLMDP's which don't know what those are

                self.M = AMLMDP(map, subtask_inds);
                self.next = HMLMDP(self);
            end
        end

        function solve(self, goal)
            % Pre-solve all MLMDP's of the hierarchy
            %
            cur = self;
            while ~isempty(cur.M)
                cur.M.presolve();
                if ~isempty(cur.next)
                    assert(numel(cur.M.St) == numel(cur.next.M.I));
                    cur = cur.next;
                else
                    break;
                end
            end

            % Find starting state
            %
            s = find(self.M.map == LMDP.agent_symbol);

            % Find goal state(s)
            %
            e = find(self.M.map == HMLMDP.goal_symbol);
            e = self.M.I2B(e); % get corresponding boundary state(s)
            assert(~isempty(e));
            assert(isempty(find(e == 0))); % make sure they all have corresponding boundary states

            % Set up reward structure according to goal state(s)
            %
            rb = MLMDP.R_B_nongoal * ones(numel(self.M.B), 1); % non-goal B states have q = 0
            rb(find(self.M.B == e)) = HMLMDP.R_goal; % goal B states have an actual reward
            rb(ismember(self.M.B, self.M.St)) = HMLMDP.R_St; % St states have a small reward to encourage exploring them every now and then

            % Find solution on current level based on reward structure
            %
            self.M.solveMLMDP(rb);

            % Solve the HMLMDP by sampling from multiple levels
            % TODO dedupe with sample
            %
            Rtot = 0;

            map = self.M.map;
            disp(map)

            iter = 1;
            while true
                Rtot = Rtot + self.M.R(s);

                [x, y] = self.M.I2pos(s);
                
                new_s = samplePF(self.M.a(:,s));

                if ismember(new_s, self.M.I)
                    % Internal state -> just move to it
                    %
                    [new_x, new_y] = self.M.I2pos(new_s);
                    map(x, y) = LMDP.empty_symbol;
                    map(new_x, new_y) = LMDP.agent_symbol;
                    fprintf('(%d, %d) --> (%d, %d)\n', x, y, new_x, new_y);
                    disp(map);

                    s = new_s;

                elseif ismember(new_s, self.M.St)
                    % Higher layer state i.e. subtask state
                    %
                    s_next_level = find(self.M.St == new_s); % St state on current level == I state on higher level

                    fprintf('NEXT LEVEL BITCH! (%d, %d) --> %d !!!\n', x, y, s_next_level);

                    % solve next level MLMDP
                    %
                    rb_next_level = [4 -1]'; % TODO HARDCODED FIXME
                    self.next.M.solveMLMDP(rb_next_level);

                    % sample until a boundary state
                    %
                    [~, path] = self.next.M.sample(s_next_level);

                    % s_next_level = path(end-1); % = the last I state on the next level = the next St state on this level 
                    % TODO ????? or not....

                    % recalculate reward structure on current level
                    % based on the optimal policy on the higher level
                    %
                    ai = self.next.M.a(self.next.M.I, :);
                    Pi = self.next.M.P(self.next.M.I, :);
                    rt = (ai(:, s_next_level) - Pi(:, s_next_level)) * self.rt_coef; % Eq 10 from Saxe et al (2017)
                    assert(size(rt, 1) == numel(self.M.St));
                    assert(size(rt, 2) == 1);
                    fprintf('                rt = [%s]\n', sprintf('%d ', rt));
                    fprintf('                old rb = [%s]\n', sprintf('%d ', rb));
                    rb(ismember(self.M.B, self.M.St)) = rt;
                    fprintf('                new rb = [%s]\n', sprintf('%d ', rb));

                    % recompute the optimal policy based on the 
                    % new reward structure
                    %
                    w = self.M.solveMLMDP(rb);
                    fprintf('   w = [%s]\n', sprintf('%d ', w));

                    fprintf('....END NEXT LEVEL %d --> (%d, %d)!!!\n', s_next_level, x, y);
                else
                    fprintf('(%d, %d) --> END\n', x, y);

                    Rtot = Rtot + self.M.R(new_s);
                    break
                end

                iter = iter + 1;
                if iter >= 20, break; end
            end

            fprintf('Total reward: %d\n', Rtot);
        end
    end

end
