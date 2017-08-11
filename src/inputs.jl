#modified from NIDAQ.read
#idea:  could modify this to be mutating (!) function that writes to a view of a bigger array.
#       but warning! the input data vector must be the correct size and contiguous in memory
function read_analog(t::NIDAQ.AITask, precision::DataType, num_samples_per_chan::Integer = -1; timeout::Float64=-1.0)
    num_channels = getproperties(t)["NumChans"][1]
    num_samples_per_chan_read = Int32[0]
    buffer_size = num_samples_per_chan==-1 ? 1024 : num_samples_per_chan
    data = Array{precision}(buffer_size*num_channels)
    NIDAQ.catch_error( NIDAQ.read_analog_cfunctions[precision](t.th,
                                                        convert(Int32,num_samples_per_chan),
                                                        timeout,
                                                        reinterpret(Bool32,NIDAQ.Val_GroupByScanNumber),
                                                        pointer(data),
                                                        convert(UInt32,buffer_size*num_channels),
                                                        pointer(num_samples_per_chan_read),
                                                        reinterpret(Ptr{Bool32},C_NULL)) )
    if num_samples_per_chan_read[1] != num_samples_per_chan
        error("Read $num_samples_per_chan_read samples instead of the $num_samples_per_chan samples requested")
    end
    #data = data[1:num_samples_per_chan_read[1]*num_channels]
    #num_channels==1 ? data : reshape(data, (convert(Int64, num_channels), div(length(data),num_channels)))
    return data
end

function read_digital(t::NIDAQ.DITask, precision::DataType, num_samples_per_chan::Integer = -1; timeout::Float64=-1.0)
    num_channels = getproperties(t)["NumChans"][1]
    num_samples_per_chan_read = Int32[0]
    buffer_size = num_samples_per_chan==-1 ? 1024 : num_samples_per_chan
    data = Array{precision}(buffer_size*num_channels)
    NIDAQ.catch_error( NIDAQ.read_digital_cfunctions[precision](t.th,
        convert(Int32,num_samples_per_chan),
        timeout,
        reinterpret(Bool32,NIDAQ.Val_GroupByScanNumber),
        pointer(data),
        convert(UInt32,buffer_size*num_channels),
        pointer(num_samples_per_chan_read),
        reinterpret(Ptr{Bool32},C_NULL)) )
    if num_samples_per_chan_read[1] != num_samples_per_chan
        error("Read $num_samples_per_chan_read samples instead of the $num_samples_per_chan samples requested")
    end
    #data = data[1:num_samples_per_chan_read[1]*num_channels]
    #num_channels==1 ? data : reshape(data, (convert(Int64, num_channels, div(length(data),num_channels))))
    return data
end 

function prepare_ai(coms, nsamps::Integer, bufsz::Int, trigger_terminal::String; terminal_config = "referenced single-ended")
    print("preparing DAQ for ai...\n")
    rig = rig_name(coms[1])
    usb_req_size = Ref{UInt32}(0)
    chns = map(daq_channel, coms)
    nchans = length(coms)
    tsk = []
    if !in(split(DEVICE_PREFIX, "/")[1], NIDAQ.devices())
        error("Device $DEVICE_PREFIX not detected")
    end
    for i = 1:length(chns)
        if i == 1
            tsk = analog_input(DEVICE_PREFIX * chns[1], terminal_config = terminal_config)
        else
            analog_input(tsk, DEVICE_PREFIX * chns[i])
            setproperty!(tsk, DEVICE_PREFIX * chns[i], "Max", 10.0) #"/ao0:1", "Max", 10.0)
        end
    end
    if rig == "dummy-6002"
        #note: default Xfer size seems to be 8000 bytes (4000 samples)
        NIDAQ.catch_error(NIDAQ.GetAIUsbXferReqSize(tsk.th, Vector{UInt8}(DEVICE_PREFIX * chns[1]), usb_req_size))
        #See article here http://digital.ni.com/public.nsf/allkb/B7B47F50F9813DFD862575890054EF7C
        usb_req_size = Ref{UInt32}(usb_req_size[] * UInt32(2))
        for i = 1:length(chns)
            print("    Set Usb transfer request size for AI\n")            
            NIDAQ.catch_error(NIDAQ.SetAIUsbXferReqSize(tsk.th, Vector{UInt8}(DEVICE_PREFIX * chns[i]), usb_req_size[]))
        end
    end
    NIDAQ.catch_error(NIDAQ.CfgSampClkTiming(tsk.th,
            convert(Ref{UInt8},b""),
            Float64(ustrip(samprate(first(coms)))),
            NIDAQ.Val_Rising,
            NIDAQ.Val_FiniteSamps,
            UInt64(nsamps)))
    NIDAQ.catch_error(NIDAQ.DAQmxCfgInputBuffer(tsk.th, UInt32(bufsz)))
    #print("AI buffer size (nsamps): $bufsz\n")
    if trigger_terminal != "disabled"
        print("    setting up digital start trigger for analog recording...\n")
        props = NIDAQ.getproperties(String(split(DEVICE_PREFIX, "/")[1]))
        terms = props["Terminals"][1]
        if !in("/" * DEVICE_PREFIX * trigger_terminal, terms)
            error("Terminal $trigger_terminal is does not exist.  Check valid t erminals with NIDAQ.getproperties(dev)[\"Terminals\"]")
        end
        NIDAQ.catch_error(NIDAQ.DAQmxSetStartTrigType(tsk.th, NIDAQ.Val_DigEdge))
        NIDAQ.catch_error(NIDAQ.CfgDigEdgeStartTrig(tsk.th, convert(Ref{UInt8}, convert(Array{UInt8}, "/" * DEVICE_PREFIX * trigger_terminal)), NIDAQ.Val_Rising))
    end
    return tsk
end

function prepare_di(coms, nsamps::Integer, bufsz::Int, trigger_terminal::String)
    error("Not yet implemented")
end

function _record_analog_signals{T<:ImagineSignal}(ai_name::AbstractString, coms::AbstractVector{T}, nsamps::Integer, samps_per_read::Int, trigger_terminal::String, ready_chan::RemoteChannel)
    if any(map(isdigital, coms))
        error("Only analog signals are allowed")
    end
    nchans = length(coms)
    #Differently from analog outputs, analog inputs should only be started via software if they don't use a trigger (strange design)
    autostart = trigger_terminal == "disabled" ? true : false
    tsk = prepare_ai(coms, nsamps, 2*samps_per_read, trigger_terminal)
    output_array = -1
    fid = -1
    if !isempty(ai_name)
        if isfile(ai_name)
            rm(ai_name)
        end
        open(ai_name, "w+") do fid
            output_array = Mmap.mmap(fid, Matrix{rawtype(first(coms))}, (nchans, nsamps))
        end
    else
        output_array = Matrix{rawtype(first(coms))}(nchans, nsamps)
    end
    record_loop!(output_array, mapper(first(coms)), tsk, nsamps, samps_per_read, autostart, ready_chan)
    sigs = parse_ai(output_array, map(daq_channel, coms), rig_name(first(coms)), samprate(first(coms)))
    return sigs
end

function _record_digital_signals{T<:ImagineSignal}(di_name::AbstractString, coms::AbstractVector{T}, nsamps::Integer, samps_per_read::Int, trigger_terminal::String)
    if !all(map(isdigital, coms))
        error("Only digital signals are allowed")
    end
    nchans = length(coms)
    autostart = trigger_terminal == "disabled" ? true : false
    tsk = prepare_di(coms, nsamps, 2*samps_per_read, trigger_terminal)
    fid = open(di_name, "w+")
    output_array = Mmap.mmap(fid, BitArray, (nchans, nsamps))
    try
        record_loop!(output_array, mapper(first(coms)), tsk, nsamps, samps_per_read, autostart)
    finally
        output_array = 0
        close(fid)
        gc()
    end
    return myid()
end

#Should work for both analog and digital
function record_loop!{Traw, TV, TW}(output::Matrix{Traw}, m::ImagineInterface.SampleMapper{Traw, TV, TW}, tsk, nsamps::Integer, samps_per_read::Integer, autostart::Bool, ready_chan::RemoteChannel)
    nsamps = size(output,2)
    nchans = size(output,1)
    finished = false
    curstart = 1
    read_incr = samps_per_read - 1
    is_digi = isa(tsk, NIDAQ.DITask)
    if is_digi
        pp = x->Traw(x)
    else #it's an analog voltage
        pp = x-> ImagineInterface.volts2raw(m)(x*Unitful.V)
    end
    try
        if autostart
            start(tsk)
        end
        put!(ready_chan, myid())
        while !finished
            curstop = curstart + read_incr
            if curstop >= nsamps
                finished = true
                curstop = min(nsamps, curstop)
            end
            nsamps_to_read = curstop - curstart + 1
            #now read from buffer
            if !is_digi
                output[:, curstart:curstop] = map(pp, read_analog(tsk, Float64, nsamps_to_read, timeout=-1.0))
            else
                output[:, curstart:curstop] = map(pp, read_digital(tsk, UInt8, nsamps_to_read, timeout=-1.0))
            end
            print("So far $curstop of $nsamps samples have been read...\n")
            curstart = curstop + 1
        end
    catch
        clear(tsk)
        rethrow()
    end
    #print("waiting until task is done...\n")
    NIDAQ.catch_error(NIDAQ.WaitUntilTaskDone(tsk.th, 0.0)) #should be done already, throw error if not
    stop(tsk)
    clear(tsk)
    return true
end