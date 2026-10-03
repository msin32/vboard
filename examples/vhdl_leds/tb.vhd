library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb is end entity;

architecture sim of tb is
  signal clk : std_logic := '0';
  signal btn : std_logic_vector(3 downto 0) := "0000";
  signal sw  : std_logic_vector(7 downto 0) := x"01";   -- fast count
  signal led : std_logic_vector(7 downto 0);
  signal seg : std_logic_vector(6 downto 0);
  signal dig : std_logic_vector(3 downto 0);
begin
  dut : entity work.top port map (clk => clk, btn => btn, sw => sw, led => led, seg => seg, dig => dig);

  clk <= not clk after 20 ns;   -- 25 MHz

  process
  begin
    wait for 100 ms;            -- fast mode counts every 2**20 clocks (~42 ms)
    assert led /= x"00" report "counter did not advance" severity failure;
    report "PASS: led = " & integer'image(to_integer(unsigned(led)));
    std.env.stop;
  end process;
end architecture;
