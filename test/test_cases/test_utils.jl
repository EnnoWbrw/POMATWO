"""
Tests for utility functions in:
  - src/utils/time_utils.jl  (split, prev_period)
  - src/utils/get_vals_utils.jl  (FixedProfile, HourlyProfile getindex / length)
"""

function test_utils()
    @testset "Time Utilities" begin

        # ─────────────────────────────────────────────────────────────────────
        @testset "split(start, step, stop)" begin
            # Basic full split
            result = POMATWO.split(1, 2, 6)
            @test result == [1:2, 3:4, 5:6]

            # Odd total length: last chunk smaller
            result2 = POMATWO.split(1, 2, 5)
            @test result2 == [1:2, 3:4, 5:5]

            # Step >= stop-start+1: only one chunk
            result3 = POMATWO.split(1, 10, 4)
            @test result3 == [1:4]

            # Single time-step
            result4 = POMATWO.split(3, 1, 3)
            @test result4 == [3:3]

            # All chunks cover start:stop
            for chunk in POMATWO.split(1, 3, 12)
                @test first(chunk) >= 1
                @test last(chunk)  <= 12
            end
            all_t = reduce(vcat, collect.(POMATWO.split(1, 3, 12)))
            @test all_t == collect(1:12)
        end

        # ─────────────────────────────────────────────────────────────────────
        @testset "split(th::TimeHorizon)" begin
            # No offset: behaves like split(start, step, stop)
            th1 = TimeHorizon(start=1, stop=6, split=2, offset=0)
            result1 = POMATWO.split(th1)
            @test result1 == [1:2, 3:4, 5:6]

            # Offset > 0: prepend [start:offset], then regular split
            th2 = TimeHorizon(start=1, stop=8, split=3, offset=2)
            result2 = POMATWO.split(th2)
            @test first(result2) == 1:2      # the prefix chunk
            # Remaining chunks cover 3:8 with step 3
            tail = reduce(vcat, collect.(result2[2:end]))
            @test tail == collect(3:8)

            # Split=stop means one single chunk
            th3 = TimeHorizon(start=1, stop=4, split=4, offset=0)
            result3 = POMATWO.split(th3)
            @test result3 == [1:4]

            # TimeHorizon default (split=24 > stop=4) → one chunk [1:4]
            th_no_split = TimeHorizon(stop=4)
            @test POMATWO.split(th_no_split) == [1:4]
        end

        # ─────────────────────────────────────────────────────────────────────
        @testset "prev_period" begin
            T = 1:4

            # First element wraps to last
            @test POMATWO.prev_period(T, 1) == 4

            # Normal predecessor
            @test POMATWO.prev_period(T, 2) == 1
            @test POMATWO.prev_period(T, 3) == 2
            @test POMATWO.prev_period(T, 4) == 3

            # Error for out-of-range t
            @test_throws Exception POMATWO.prev_period(T, 5)
            @test_throws Exception POMATWO.prev_period(T, 0)
        end
    end  # testset "Time Utilities"

    # ─────────────────────────────────────────────────────────────────────────
    @testset "Profile Types" begin

        @testset "FixedProfile" begin
            fp = POMATWO.FixedProfile(42.0)
            @test fp[1]   == 42.0
            @test fp[5]   == 42.0    # any index returns constant
            @test fp[100] == 42.0
            @test length(fp) == 1

            fp_int = POMATWO.FixedProfile(0)
            @test fp_int[1] == 0
            @test length(fp_int) == 1
        end

        @testset "HourlyProfile" begin
            vals = [1.0, 2.0, 3.0, 4.0]
            hp = POMATWO.HourlyProfile(vals)
            @test hp[1] == 1.0
            @test hp[2] == 2.0
            @test hp[4] == 4.0
            @test length(hp) == 4

            # Mutation of backing array does not affect profile (copy on construction)
            hp2 = POMATWO.HourlyProfile([10.0, 20.0])
            @test hp2[1] == 10.0
            @test hp2[2] == 20.0
        end
    end  # testset "Profile Types"
end
