defmodule Stack.Filter do
  @moduledoc """
  A builder for composing filters that wrap a service.

  A filter builds a fun that takes an input request and a 1-arity fun and returns an
  output response. Filters are composed until they wrap a service, which is the source
  for the fun. Once a service is wrapped the filter is transformed into a service with
  the same input and output as the filter.
  """
  alias Stack.{Service, Filter}

  defstruct stack: []

  @dialyzer {:no_opaque, into: 2, call: 3}

  @typedoc """
  A filter with external and internal request and reply parameters

  The first parameter is request, or input, to the filter.
  The second parameter is reply, our output, to the filter.
  The third parameter is the request for the wrapped service or filter.
  The fourth parameter is the reply for the wrapped service of filter.
  """
  @opaque t(req_in, rep_out, _req_out, _rep_in) :: %Filter{stack: Stack.t(req_in, rep_out)}

  @callback init(args) :: state when args: term, state: term
  @callback call(_req_in, (_req_out -> _rep_in), state) :: _rep_out
            when _req_in: var, _req_out: var, _rep_in: var, state: term, _rep_out: var

  @doc """
  Create a new (identity) filter.
  """
  @spec new() :: t(req, rep, req, rep) when req: var, rep: var
  def new(), do: %Filter{}

  @doc """
  Create a new filter with a fun.

  The filter will call the fun with the input and wrapped service's fun, and
  returns the output.
  """
  @spec new((req_in, (req_out -> rep_in) -> rep_out)) :: t(req_in, rep_out, req_out, rep_in)
        when req_in: var, req_out: var, rep_in: var, rep_out: var
  def new(transformer) when is_function(transformer, 2) do
    %Filter{stack: [{:into, transformer}]}
  end

  @doc """
  Create a new filter with a callback module.

  The filter will call the callback module with the input and wrapped service's fun, and
  returns the output.
  """
  @spec new(module, args) :: t(_req_in, _rep_out, _req_out, _rep_in)
        when args: term, _req_in: var, _req_out: var, _rep_in: var, _rep_out: var
  def new(module, args) when is_atom(module) do
    state = module.init(args)
    %Filter{stack: [{:into, module, state}]}
  end

  @doc """
  Transform the input and output of the wrapped service, or wrap a service.

  If the second argument is a fun or filter, that fun or filter will wrap the service.
  This can change the request/reply of the wrapped service but not the external request
  and reply as the current filter is wrapping it.

  If the second argument is a service, the filter wraps the service and returns a new
  service with the input and output matching that of the request and reply of the
  filter.
  """
  @spec into(t(req_in, rep_out, req_out, rep_in), (req_out, (req -> rep) -> rep_in)) ::
          t(req_in, rep_out, req, rep)
        when req_in: var, rep_out: var, req_out: var, rep_in: var, req: var, rep: var
  def into(%Filter{stack: stack} = f, transformer) when is_function(transformer, 2) do
    %Filter{f | stack: [{:into, transformer} | stack]}
  end

  @spec into(t(req_in, rep_out, req_out, rep_in), t(req_out, rep_in, req, rep)) ::
          t(req_in, rep_out, req, rep)
        when req_in: var, rep_out: var, req_out: var, rep_in: var, req: var, rep: var
  def into(%Filter{stack: stack1} = f, %Filter{stack: stack2}) do
    %Filter{f | stack: stack2 ++ stack1}
  end

  @spec into(t(req_in, rep_out, req_out, rep_in), Service.t(req_out, rep_in)) ::
          Service.t(req_in, rep_out)
        when req_in: var, rep_out: var, req_out: var, rep_in: var
  def into(%Filter{stack: stack1}, %Service{stack: stack2} = s) do
    %Service{s | stack: Enum.reverse(stack1, stack2)}
  end

  @doc """
  Transform the result returned, or exception raised, by the wrapped service.
  """
  @spec transform((res -> rep), (req, Exception.t(), Exception.stacktrace() -> rep)) ::
          t(req, rep, req, res)
        when req: var, rep: var, res: var
  def transform(mapper, handler) when is_function(mapper, 1) and is_function(handler, 3) do
    Filter.new(fn req, service ->
      try do
        service.(req)
      catch
        :error, error ->
          stack = System.stacktrace()
          exception = Exception.normalize(:error, error, stack)
          handler.(req, exception, stack)
      else
        res ->
          mapper.(res)
      end
    end)
  end

  @doc """
  Handle an exception raised by the wrapped service.
  """
  @spec handle((req, Exception.t(), Exception.stacktrace() -> rep)) :: t(req, rep, req, rep)
        when req: var, rep: var
  def handle(handler) when is_function(handler, 3) do
    transform(fn res -> res end, handler)
  end

  @doc """
  Create a new filter that ensures a fun is always run after the wrapped service.
  """
  @spec ensure((req -> res)) :: t(req, rep, req, rep) when req: var, res: term, rep: var
  def ensure(ensurer) when is_function(ensurer, 1) do
    Filter.new(fn req, service ->
      try do
        service.(req)
      after
        _ = ensurer.(req)
      end
    end)
  end

  @doc """
  Create an anonymous function that transforms the input to output by applying an anonymous function.
  """
  @spec init(t(req_in, rep_out, req_out, rep_in)) :: (req_in, (req_out -> rep_in) -> rep_out)
        when req_in: var, rep_out: var, req_out: var, rep_in: var
  def init(%Filter{stack: stack}) do
    reverse_stack = Enum.reverse(stack)
    &Stack.eval(reverse_stack, &1, &2)
  end

  @doc """
  Call the filter with input, and fun or wrapped service.
  """
  @spec call(t(req_in, rep_out, req_out, rep_in), req_in, (req_out -> rep_in)) :: rep_out
        when req_in: var, rep_out: var, req_out: var, rep_in: var
  def call(%Filter{stack: stack}, req, mapper) when is_function(mapper, 1) do
    stack
    |> Enum.reverse()
    |> Stack.eval(req, mapper)
  end

  @spec call(t(req_in, rep_out, req_out, rep_in), req_in, Service.t(req_out, rep_in)) :: rep_out
        when req_in: var, rep_out: var, req_out: var, rep_in: var
  def call(%Filter{stack: stack1}, req, %Service{stack: stack2}) do
    stack1
    |> Enum.reverse(stack2)
    |> Stack.eval(req)
  end
end
